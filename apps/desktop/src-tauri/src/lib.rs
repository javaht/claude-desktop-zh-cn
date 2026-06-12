use claude_zh_core::{
    CliRequest, EnvironmentReport, InstallRequest, LogEvent, LogSink, LogSinkExt, RestoreRequest,
};
use claude_zh_platform::{self as platform, FileLogger, ResourceReleaseManifest};
use serde::Serialize;
use std::{
    collections::HashMap,
    env, fs,
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    sync::{Mutex, MutexGuard, OnceLock},
    time::Instant,
};
use tauri::{async_runtime, AppHandle, Emitter, Manager};

/// finished 的 action log entry 保留时长（秒），超过后由 drain/init 清理。
const ACTION_LOG_TTL_SECS: u64 = 60;

static ACTION_LOGS: OnceLock<Mutex<HashMap<String, ActionLogState>>> = OnceLock::new();

#[derive(Clone)]
struct TauriLogger {
    app: AppHandle,
    action_id: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ActionStarted {
    action_id: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ActionFinished {
    action_id: String,
    action: String,
    ok: bool,
    error: Option<String>,
}

struct ActionLogState {
    logs: Vec<LogEvent>,
    finished: Option<ActionFinished>,
    finished_at: Option<Instant>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ActionLogDrain {
    logs: Vec<LogEvent>,
    next_offset: usize,
    finished: Option<ActionFinished>,
}

impl TauriLogger {
    fn new(app: AppHandle) -> Self {
        Self {
            app,
            action_id: None,
        }
    }

    fn for_action(app: AppHandle, action_id: String) -> Self {
        Self {
            app,
            action_id: Some(action_id),
        }
    }
}

impl LogSink for TauriLogger {
    fn log(&self, level: &str, message: &str) {
        let event = LogEvent {
            level: level.to_string(),
            message: message.to_string(),
        };
        if let Some(action_id) = &self.action_id {
            record_action_log(action_id, event.clone());
        } else {
            let _ = self.app.emit("installer-log", event);
        }
        println!("[{level}] {message}");
    }
}

fn action_logs() -> &'static Mutex<HashMap<String, ActionLogState>> {
    ACTION_LOGS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 获取 action log 锁；若 mutex 已 poison 则恢复而非 panic。
fn lock_action_logs() -> MutexGuard<'static, HashMap<String, ActionLogState>> {
    action_logs().lock().unwrap_or_else(|e| {
        eprintln!("[warn] action log mutex was poisoned, recovering");
        e.into_inner()
    })
}

fn init_action_log(action_id: &str) {
    let mut logs = lock_action_logs();
    if logs.len() > 64 {
        logs.retain(|_, state| match state.finished_at {
            Some(t) => t.elapsed().as_secs() < ACTION_LOG_TTL_SECS,
            None => true, // 未 finished 的 entry 保留
        });
    }
    logs.entry(action_id.to_string()).or_insert(ActionLogState {
        logs: Vec::new(),
        finished: None,
        finished_at: None,
    });
}

fn record_action_log(action_id: &str, event: LogEvent) {
    let mut logs = lock_action_logs();
    let state = logs.entry(action_id.to_string()).or_insert(ActionLogState {
        logs: Vec::new(),
        finished: None,
        finished_at: None,
    });
    state.logs.push(event);
}

fn finish_action_log(action_id: &str, finished: ActionFinished) {
    let mut logs = lock_action_logs();
    let state = logs.entry(action_id.to_string()).or_insert(ActionLogState {
        logs: Vec::new(),
        finished: None,
        finished_at: None,
    });
    state.finished = Some(finished);
    state.finished_at = Some(Instant::now());
}

fn tauri_resource_dir(app: &AppHandle) -> Option<PathBuf> {
    app.path().resource_dir().ok()
}

#[tauri::command]
fn detect_environment(app: AppHandle) -> EnvironmentReport {
    platform::detect_environment(tauri_resource_dir(&app))
}

#[tauri::command]
fn resource_release_manifest(app: AppHandle) -> Result<ResourceReleaseManifest, String> {
    platform::resource_release_manifest(tauri_resource_dir(&app)).map_err(|error| error.to_string())
}

async fn run_blocking_action<F>(app: AppHandle, action: F) -> Result<(), String>
where
    F: FnOnce(TauriLogger, Option<PathBuf>) -> claude_zh_core::Result<()> + Send + 'static,
{
    let resource_dir = tauri_resource_dir(&app);
    let logger = TauriLogger::new(app);
    let task_logger = logger.clone();
    match async_runtime::spawn_blocking(move || action(task_logger, resource_dir)).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(error)) => {
            let message = error.to_string();
            logger.error(&message);
            Err(message)
        }
        Err(error) => {
            let message = format!("后台任务异常: {error}");
            logger.error(&message);
            Err(message)
        }
    }
}

fn spawn_background_action<F>(
    app: AppHandle,
    action: &'static str,
    action_id: String,
    task: F,
) -> ActionStarted
where
    F: FnOnce(TauriLogger, Option<PathBuf>) -> claude_zh_core::Result<()> + Send + 'static,
{
    init_action_log(&action_id);
    let resource_dir = tauri_resource_dir(&app);
    let logger = TauriLogger::for_action(app.clone(), action_id.clone());
    let task_app = app.clone();
    let task_action_id = action_id.clone();
    logger.info(format!("后台任务已启动：{action}，日志会持续写入下方。"));
    async_runtime::spawn_blocking(move || {
        let task_logger = TauriLogger::for_action(task_app.clone(), task_action_id.clone());
        let result = catch_unwind(AssertUnwindSafe(|| {
            task(task_logger.clone(), resource_dir).map_err(|error| error.to_string())
        }));
        let error = match result {
            Ok(Ok(())) => None,
            Ok(Err(msg)) => Some(msg),
            Err(panic_payload) => {
                let message = if let Some(s) = panic_payload.downcast_ref::<&str>() {
                    s.to_string()
                } else if let Some(s) = panic_payload.downcast_ref::<String>() {
                    s.clone()
                } else {
                    "unknown panic".to_string()
                };
                Some(format!("后台任务发生 panic: {message}"))
            }
        };
        if let Some(message) = &error {
            task_logger.error(message);
        }
        let finished = ActionFinished {
            action_id: task_action_id,
            action: action.to_string(),
            ok: error.is_none(),
            error,
        };
        finish_action_log(&finished.action_id, finished.clone());
        let _ = task_app.emit("installer-action-finished", finished);
    });
    ActionStarted { action_id }
}

#[tauri::command]
fn install_patch(app: AppHandle, action_id: String, request: InstallRequest) -> ActionStarted {
    spawn_background_action(
        app,
        "安装中文补丁",
        action_id,
        move |logger, resource_dir| {
            let resources = platform::resolve_resources(resource_dir)?;
            platform::install_patch(&resources, &request, &logger)
        },
    )
}

#[tauri::command]
fn drain_action_logs(action_id: String, offset: usize) -> ActionLogDrain {
    let mut logs = lock_action_logs();
    let Some(state) = logs.get(&action_id) else {
        return ActionLogDrain {
            logs: Vec::new(),
            next_offset: offset,
            finished: None,
        };
    };
    let start = offset.min(state.logs.len());
    let drained_logs = state.logs[start..].to_vec();
    let next_offset = state.logs.len();
    let finished = state.finished.clone();
    // M6: 仅当 finished 且 TTL 过期后才清理 entry，避免前端 IPC 重试时数据丢失
    let should_remove = state
        .finished_at
        .is_some_and(|t| t.elapsed().as_secs() >= ACTION_LOG_TTL_SECS);
    if should_remove {
        logs.remove(&action_id);
    }
    ActionLogDrain {
        logs: drained_logs,
        next_offset,
        finished,
    }
}

#[tauri::command]
fn restore_patch(
    app: AppHandle,
    action_id: String,
    request: Option<RestoreRequest>,
) -> ActionStarted {
    let request = request.unwrap_or_default();
    spawn_background_action(app, "恢复原样", action_id, move |logger, _| {
        platform::restore_patch(request.dry_run, &logger)
    })
}

#[tauri::command]
fn install_resource_update(
    app: AppHandle,
    action_id: String,
    zipball_url: String,
    release: String,
) -> ActionStarted {
    spawn_background_action(
        app,
        "更新补丁资源",
        action_id,
        move |logger, resource_dir| {
            platform::install_resource_update(resource_dir, &zipball_url, &release, &logger)
        },
    )
}

#[tauri::command]
async fn set_auto_updates(app: AppHandle, enabled: bool) -> Result<(), String> {
    run_blocking_action(app, move |logger, _| {
        platform::set_auto_updates(enabled, &logger)
    })
    .await
}

fn run_cli_file(path: PathBuf) -> i32 {
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) => {
            eprintln!("{error}");
            return 2;
        }
    };
    let request: CliRequest = match serde_json::from_str(&text) {
        Ok(request) => request,
        Err(error) => {
            eprintln!("{error}");
            return 2;
        }
    };
    platform::set_file_logger_silent_stdout(true);
    let logger_path = request.log_path.clone();
    let logger = logger_path
        .map(FileLogger::new)
        .unwrap_or_else(|| FileLogger::new(env::temp_dir().join("claude-zh-cn-rs-cli.jsonl")));
    match platform::run_cli_request(request, &logger) {
        Ok(()) => 0,
        Err(error) => {
            logger.error(error.to_string());
            1
        }
    }
}

pub fn run() {
    let mut args = env::args().skip(1);
    if let Some(first) = args.next() {
        if first == "--cli-file" {
            let Some(path) = args.next() else {
                eprintln!("missing --cli-file path");
                std::process::exit(2);
            };
            std::process::exit(run_cli_file(PathBuf::from(path)));
        }
        if first == "--cli-action" {
            let Some(action) = args.next() else {
                eprintln!("missing --cli-action value");
                std::process::exit(2);
            };

            // 解析 --enabled 参数（支持 --enabled=true 或 --enabled true）
            let remaining: Vec<String> = args.collect();
            let enabled = match platform::parse_enabled_flag(&remaining) {
                Ok(v) => v,
                Err(msg) => {
                    eprintln!("{msg}");
                    std::process::exit(2);
                }
            };

            if action == "set_auto_updates" && enabled.is_none() {
                eprintln!("set_auto_updates 需要 --enabled 参数");
                std::process::exit(2);
            }

            platform::set_file_logger_silent_stdout(true);
            let logger = FileLogger::new(env::temp_dir().join("claude-zh-cn-rs-cli.jsonl"));
            let request = CliRequest {
                action,
                install: None,
                restore: None,
                enabled,
                resources_path: None,
                log_path: None,
            };
            if let Err(error) = platform::run_cli_request(request, &logger) {
                logger.error(error.to_string());
                std::process::exit(1);
            }
            return;
        }
    }

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            detect_environment,
            resource_release_manifest,
            install_patch,
            drain_action_logs,
            restore_patch,
            install_resource_update,
            set_auto_updates
        ])
        .setup(|app| {
            // Windows 平台启用原生窗口装饰（标题栏 + 控制按钮），
            // 回避 WebView2 无边框模式下自绘内容大面积不可见的渲染问题。
            // 失败时仅记录日志，不阻塞应用启动。
            #[cfg(target_os = "windows")]
            {
                if let Some(window) = app.get_webview_window("main") {
                    if let Err(err) = window.set_decorations(true) {
                        eprintln!("[tauri setup] 启用 Windows 原生装饰失败: {err}");
                    }
                } else {
                    eprintln!("[tauri setup] 找不到 label 为 main 的 webview 窗口，跳过 set_decorations");
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
