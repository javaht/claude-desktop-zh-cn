use chrono::Local;
#[cfg(windows)]
use claude_zh_core::{
    asar_header_hash, copy_file, patched_version_record, remove_language_files, unregister_language,
};
use claude_zh_core::{
    auto_updates_enabled, config_library_set_auto_updates, err, find_skills_plugin_root,
    install_into_resources, read_json, remove_path, set_config_locale, sync_skills_impl,
    write_json, CliRequest, CoreError, EnvironmentReport, InstallPaths, InstallRequest, LogEvent,
    LogSink, LogSinkExt, Result,
};
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::{
    env,
    ffi::OsStr,
    fs,
    io::{BufRead, BufReader, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;
#[cfg(any(target_os = "macos", windows))]
use walkdir::WalkDir;

#[cfg(windows)]
const WATCHER_TASK: &str = "ClaudeDesktopZhCn-UpdateWatcher";
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

pub struct FileLogger {
    path: PathBuf,
}

impl FileLogger {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }
}

impl LogSink for FileLogger {
    fn log(&self, level: &str, message: &str) {
        let event = LogEvent {
            level: level.to_string(),
            message: message.to_string(),
        };
        if let Some(parent) = self.path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(mut file) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
        {
            let _ = serde_json::to_writer(&mut file, &event);
            let _ = file.write_all(b"\n");
        }
        println!("[{level}] {message}");
    }
}

pub fn run_command(mut command: Command, logger: &dyn LogSink, label: &str) -> Result<String> {
    logger.info(format!("执行: {label}"));
    hide_command_window(&mut command);
    let output = command
        .stderr(Stdio::piped())
        .stdout(Stdio::piped())
        .output()?;
    let mut text = String::new();
    text.push_str(&String::from_utf8_lossy(&output.stdout));
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    for line in text.lines() {
        if !line.trim().is_empty() {
            logger.info(line);
        }
    }
    if !output.status.success() {
        return err(format!("{label} 失败，退出码: {}", output.status));
    }
    logger.info(format!("完成: {label}"));
    Ok(text)
}

#[cfg(windows)]
fn hide_command_window(command: &mut Command) {
    command.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn hide_command_window(_command: &mut Command) {}

pub fn resource_candidates(tauri_resource_dir: Option<PathBuf>) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(resource_dir) = tauri_resource_dir {
        out.push(resource_dir.join("resources"));
        out.push(resource_dir.join("_up_/_up_/resources"));
        out.push(resource_dir.join("_up_/resources"));
        out.push(resource_dir);
    }
    if let Ok(exe) = env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            out.push(exe_dir.join("resources"));
            out.push(exe_dir.join("_up_/_up_/resources"));
            out.push(exe_dir.join("_up_/resources"));
            out.push(exe_dir.join("../Resources/resources"));
            out.push(exe_dir.join("../Resources"));
            out.push(exe_dir.join("../../../../resources"));
        }
    }
    if let Ok(manifest_dir) = env::var("CARGO_MANIFEST_DIR") {
        out.push(PathBuf::from(manifest_dir).join("../../../resources"));
    }
    if let Ok(current) = env::current_dir() {
        out.push(current.join("resources"));
        out.push(current.join("../resources"));
        out.push(current.join("../../resources"));
        out.push(current.join("../../../resources"));
    }
    out
}

pub fn resolve_resources(tauri_resource_dir: Option<PathBuf>) -> Result<PathBuf> {
    for candidate in resource_candidates(tauri_resource_dir) {
        let marker = candidate.join("frontend-zh-CN.json");
        if marker.is_file() {
            return Ok(candidate.canonicalize().unwrap_or(candidate));
        }
    }
    err("未找到随包 resources 目录。")
}

pub fn detect_environment(resources_dir: Option<PathBuf>) -> EnvironmentReport {
    let resources = resolve_resources(resources_dir).ok();
    let resource_issues = resources
        .as_ref()
        .map(|path| claude_zh_core::verify_language_resource_files(path))
        .unwrap_or_else(|| vec!["未找到 resources 目录。".to_string()]);
    let claude = detect_claude();
    let is_admin = is_admin();
    let backup_count = backup_count_for_detected_claude(claude.as_ref());
    let mut warnings = Vec::new();
    if claude.is_none() {
        warnings.push("未检测到 Claude Desktop 安装。".to_string());
    }
    if !resource_issues.is_empty() {
        warnings.push("随包资源检查未通过。".to_string());
    }
    EnvironmentReport {
        platform: platform_name().to_string(),
        arch: env::consts::ARCH.to_string(),
        resources_dir: resources.as_ref().map(|path| path.display().to_string()),
        resources_ok: resource_issues.is_empty(),
        resource_issues,
        claude_path: claude.as_ref().map(|(app, _, _)| app.display().to_string()),
        resources_path: claude
            .as_ref()
            .map(|(_, resources, _)| resources.display().to_string()),
        install_kind: claude.as_ref().map(|(_, _, kind)| kind.clone()),
        is_admin,
        needs_admin: claude.is_some() && !is_admin,
        current_locale: current_locale(),
        backup_count,
        cc_switch_skills_dir: cc_switch_skills_dir().map(|path| path.display().to_string()),
        skills_plugin_root: skills_plugin_root().map(|path| path.display().to_string()),
        auto_updates_enabled: auto_updates_enabled(config_library_paths()),
        warnings,
    }
}

pub fn run_cli_request(request: CliRequest, logger: &dyn LogSink) -> Result<()> {
    let resources = if let Some(path) = request.resources_path {
        path
    } else {
        resolve_resources(None)?
    };
    match request.action.as_str() {
        "install_patch" => {
            let install = request
                .install
                .ok_or_else(|| CoreError::Message("缺少 install 参数。".to_string()))?;
            install_patch(&resources, &install, logger)
        }
        "restore_patch" => restore_patch(logger),
        "set_auto_updates" => set_auto_updates(request.enabled.unwrap_or(true), logger),
        "sync_cc_switch_skills" => sync_cc_switch_skills(logger),
        "unsync_cc_switch_skills" => unsync_cc_switch_skills(logger),
        "watch-once" => {
            logger.info("更新守护 CLI 已启动。");
            Ok(())
        }
        other => err(format!("未知 CLI action: {other}")),
    }
}

pub fn run_elevated_cli(
    action: &str,
    install: Option<InstallRequest>,
    enabled: Option<bool>,
    resources_path: &Path,
    logger: &dyn LogSink,
) -> Result<()> {
    let log_path = env::temp_dir().join(format!("claude-zh-cn-rs-{}.jsonl", Uuid::new_v4()));
    let request = CliRequest {
        action: action.to_string(),
        install,
        enabled,
        resources_path: Some(resources_path.to_path_buf()),
        log_path: Some(log_path.clone()),
    };
    let request_path = env::temp_dir().join(format!("claude-zh-cn-rs-{}.json", Uuid::new_v4()));
    write_json(&request_path, &serde_json::to_value(&request)?)?;
    let exe = env::current_exe()?;
    logger.info(format!("准备提权执行: {action}"));
    logger.info(format!("当前可执行文件: {}", exe.display()));
    logger.info(format!("提权请求文件: {}", request_path.display()));
    logger.info(format!("提权日志文件: {}", log_path.display()));
    logger.info(format!("随包资源目录: {}", resources_path.display()));
    if let Some(install) = &request.install {
        logger.info(format!(
            "安装参数: language={}, mode={}, launch_after={}, dry_run={}",
            install.language, install.mode, install.launch_after, install.dry_run
        ));
    }
    if let Some(enabled) = request.enabled {
        logger.info(format!("自动更新参数: enabled={enabled}"));
    }
    logger.info("需要管理员权限，正在请求系统授权。");

    let mut child = elevated_command(&exe, &request_path)?
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    logger.info("授权流程已提交，正在等待管理员子进程写入日志。");
    let start = Instant::now();
    let mut offset = 0u64;
    let mut next_heartbeat = 5u64;
    loop {
        offset = drain_jsonl_log(&log_path, offset, logger)?;
        if let Some(status) = child.try_wait()? {
            let _ = drain_jsonl_log(&log_path, offset, logger)?;
            let output = child.wait_with_output()?;
            for line in String::from_utf8_lossy(&output.stdout).lines() {
                if !line.trim().is_empty() {
                    logger.info(line);
                }
            }
            for line in String::from_utf8_lossy(&output.stderr).lines() {
                if !line.trim().is_empty() {
                    logger.warn(line);
                }
            }
            let _ = fs::remove_file(&request_path);
            if !status.success() {
                return err(format!("管理员子进程失败，退出码: {status}"));
            }
            logger.info(format!(
                "管理员子进程完成，用时 {} 秒",
                start.elapsed().as_secs()
            ));
            return Ok(());
        }
        let elapsed = start.elapsed().as_secs();
        if elapsed >= next_heartbeat {
            logger.info(format!(
                "管理员子进程仍在执行，已等待 {elapsed} 秒，继续等待日志..."
            ));
            next_heartbeat += 5;
        }
        thread::sleep(Duration::from_millis(500));
    }
}

fn drain_jsonl_log(path: &Path, offset: u64, logger: &dyn LogSink) -> Result<u64> {
    let Ok(mut file) = fs::OpenOptions::new().read(true).open(path) else {
        return Ok(offset);
    };
    file.seek(SeekFrom::Start(offset))?;
    let mut reader = BufReader::new(file);
    let mut current = offset;
    let mut line = String::new();
    loop {
        line.clear();
        let read = reader.read_line(&mut line)?;
        if read == 0 {
            break;
        }
        current += read as u64;
        if let Ok(event) = serde_json::from_str::<LogEvent>(line.trim()) {
            logger.log(&event.level, &event.message);
        }
    }
    Ok(current)
}

#[cfg(target_os = "macos")]
fn elevated_command(exe: &Path, request_path: &Path) -> Result<Command> {
    let command = format!(
        "{} --cli-file {}",
        shell_quote(&exe.display().to_string()),
        shell_quote(&request_path.display().to_string())
    );
    let script = format!(
        "do shell script {} with administrator privileges",
        serde_json::to_string(&command).unwrap_or_else(|_| "\"\"".to_string())
    );
    let mut cmd = Command::new("osascript");
    cmd.arg("-e").arg(script);
    Ok(cmd)
}

#[cfg(windows)]
fn elevated_command(exe: &Path, request_path: &Path) -> Result<Command> {
    let command = format!(
        "Start-Process -FilePath {} -ArgumentList @('--cli-file',{}) -Verb RunAs -WindowStyle Hidden -Wait",
        powershell_single_quote(&exe.display().to_string()),
        powershell_single_quote(&request_path.display().to_string())
    );
    let mut cmd = Command::new("powershell.exe");
    cmd.args([
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        &command,
    ]);
    hide_command_window(&mut cmd);
    Ok(cmd)
}

#[cfg(windows)]
fn powershell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[cfg(not(any(target_os = "macos", windows)))]
fn elevated_command(_exe: &Path, _request_path: &Path) -> Result<Command> {
    err("unsupported platform")
}

#[cfg(target_os = "macos")]
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn install_patch(resources: &Path, req: &InstallRequest, logger: &dyn LogSink) -> Result<()> {
    logger.info(format!(
        "安装请求: language={}, mode={}, launch_after={}, dry_run={}",
        req.language, req.mode, req.launch_after, req.dry_run
    ));
    logger.info(format!("使用随包资源: {}", resources.display()));
    if !is_admin() && !req.dry_run {
        logger.info("当前进程不是管理员权限，切换到系统授权安装。");
        return run_elevated_cli("install_patch", Some(req.clone()), None, resources, logger);
    }
    if req.dry_run {
        logger.info("dry-run 模式：将验证补丁流程，不会替换真实安装。");
    } else {
        logger.info("当前进程已有管理员权限，直接执行安装。");
    }
    platform_install_patch(resources, req, logger)
}

pub fn restore_patch(logger: &dyn LogSink) -> Result<()> {
    logger.info("恢复请求: 准备恢复官方 Claude.app 和英文语言配置。");
    if !is_admin() {
        let resources = resolve_resources(None)?;
        logger.info("当前进程不是管理员权限，切换到系统授权恢复。");
        return run_elevated_cli("restore_patch", None, None, &resources, logger);
    }
    logger.info("当前进程已有管理员权限，直接执行恢复。");
    platform_restore_patch(logger)
}

pub fn set_auto_updates(enabled: bool, logger: &dyn LogSink) -> Result<()> {
    logger.info(format!(
        "自动更新请求: {}",
        if enabled { "开启" } else { "停止" }
    ));
    let paths = config_library_paths();
    if paths.is_empty() {
        logger.warn("未找到 configLibrary 路径，无法写入自动更新设置。");
        return Ok(());
    }
    for path in paths {
        config_library_set_auto_updates(&path, enabled, logger)?;
    }
    logger.info("自动更新设置已写入。");
    Ok(())
}

pub fn sync_cc_switch_skills(logger: &dyn LogSink) -> Result<()> {
    logger.info("准备同步 CC Switch skills。");
    let plugin = skills_plugin_root()
        .ok_or_else(|| CoreError::Message("未找到 Claude Desktop skills plugin。".to_string()))?;
    let skills = cc_switch_skills_dir()
        .ok_or_else(|| CoreError::Message("未找到 CC Switch skills 目录。".to_string()))?;
    logger.info(format!("Claude skills plugin: {}", plugin.display()));
    logger.info(format!("CC Switch skills: {}", skills.display()));
    sync_skills_impl(&plugin, &skills, false, logger)
}

pub fn unsync_cc_switch_skills(logger: &dyn LogSink) -> Result<()> {
    logger.info("准备删除 CC Switch skills 同步。");
    let plugin = skills_plugin_root()
        .ok_or_else(|| CoreError::Message("未找到 Claude Desktop skills plugin。".to_string()))?;
    let skills = cc_switch_skills_dir()
        .ok_or_else(|| CoreError::Message("未找到 CC Switch skills 目录。".to_string()))?;
    logger.info(format!("Claude skills plugin: {}", plugin.display()));
    logger.info(format!("CC Switch skills: {}", skills.display()));
    sync_skills_impl(&plugin, &skills, true, logger)
}

#[cfg(target_os = "macos")]
pub fn platform_name() -> &'static str {
    "macOS"
}

#[cfg(windows)]
pub fn platform_name() -> &'static str {
    "Windows"
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn platform_name() -> &'static str {
    "Unsupported"
}

#[cfg(target_os = "macos")]
pub fn is_admin() -> bool {
    Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .is_some_and(|uid| uid.trim() == "0")
}

#[cfg(windows)]
pub fn is_admin() -> bool {
    let mut cmd = Command::new("cmd");
    hide_command_window(&mut cmd);
    cmd.args(["/C", "net", "session"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn is_admin() -> bool {
    false
}

pub fn user_home() -> Result<PathBuf> {
    dirs::home_dir().ok_or_else(|| CoreError::Message("无法确定用户目录。".to_string()))
}

#[cfg(target_os = "macos")]
pub fn detect_claude() -> Option<(PathBuf, PathBuf, String)> {
    let app = PathBuf::from("/Applications/Claude.app");
    let resources = app.join("Contents/Resources");
    if resources.is_dir() {
        Some((app, resources, "Applications".to_string()))
    } else {
        None
    }
}

#[cfg(windows)]
pub fn detect_claude() -> Option<(PathBuf, PathBuf, String)> {
    detect_windows_claude_in_localappdata().or_else(detect_windows_claude_in_windowsapps)
}

#[cfg(windows)]
fn windows_claude_version_key(path: &Path, prefix: &str) -> Vec<u32> {
    path.file_name()
        .and_then(OsStr::to_str)
        .and_then(|name| name.strip_prefix(prefix))
        .unwrap_or_default()
        .split(|ch: char| !ch.is_ascii_digit())
        .filter_map(|part| {
            if part.is_empty() {
                None
            } else {
                part.parse::<u32>().ok()
            }
        })
        .collect()
}

#[cfg(windows)]
fn compare_windows_claude_paths(prefix: &str, a: &PathBuf, b: &PathBuf) -> std::cmp::Ordering {
    windows_claude_version_key(b, prefix)
        .cmp(&windows_claude_version_key(a, prefix))
        .then_with(|| {
            let a_name = a.file_name().map(|name| name.to_string_lossy());
            let b_name = b.file_name().map(|name| name.to_string_lossy());
            b_name.cmp(&a_name)
        })
}

#[cfg(windows)]
pub fn detect_windows_claude_in_localappdata() -> Option<(PathBuf, PathBuf, String)> {
    let base = dirs::data_local_dir()?.join("AnthropicClaude");
    let mut apps: Vec<PathBuf> = fs::read_dir(base)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .filter(|p| {
            p.is_dir()
                && p.file_name()
                    .and_then(OsStr::to_str)
                    .is_some_and(|name| name.starts_with("app-"))
        })
        .collect();
    apps.sort_by(|a, b| compare_windows_claude_paths("app-", a, b));
    for app in apps {
        let resources = app.join("resources");
        if resources.is_dir() {
            return Some((app, resources, "Unpackaged".to_string()));
        }
    }
    None
}

#[cfg(windows)]
pub fn detect_windows_claude_in_windowsapps() -> Option<(PathBuf, PathBuf, String)> {
    let windows_apps = PathBuf::from(r"C:\Program Files\WindowsApps");
    let mut apps: Vec<PathBuf> = fs::read_dir(windows_apps)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .filter(|p| {
            p.is_dir()
                && p.file_name()
                    .and_then(OsStr::to_str)
                    .is_some_and(|name| name.starts_with("Claude_"))
        })
        .collect();
    apps.sort_by(|a, b| compare_windows_claude_paths("Claude_", a, b));
    for app in apps {
        let resources = app.join("app").join("resources");
        if resources.is_dir() {
            return Some((app, resources, "AppX".to_string()));
        }
    }
    None
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn detect_claude() -> Option<(PathBuf, PathBuf, String)> {
    None
}

pub fn current_locale() -> Option<String> {
    claude_config_paths().into_iter().find_map(|path| {
        read_json(&path).ok().and_then(|v| {
            v.get("locale")
                .and_then(serde_json::Value::as_str)
                .map(ToOwned::to_owned)
        })
    })
}

#[cfg(target_os = "macos")]
fn backup_count_for_detected_claude(_claude: Option<&(PathBuf, PathBuf, String)>) -> usize {
    fs::read_dir("/Applications")
        .ok()
        .map(|entries| {
            entries
                .flatten()
                .filter(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .starts_with("Claude.backup-before-zh-CN-")
                })
                .count()
        })
        .unwrap_or(0)
}

#[cfg(windows)]
fn backup_count_for_detected_claude(claude: Option<&(PathBuf, PathBuf, String)>) -> usize {
    claude
        .and_then(|(_, resources, _)| fs::read_dir(resources.join(".zh-cn-backups")).ok())
        .map(|entries| {
            entries
                .flatten()
                .filter(|entry| entry.path().is_dir())
                .count()
        })
        .unwrap_or(0)
}

#[cfg(not(any(target_os = "macos", windows)))]
fn backup_count_for_detected_claude(_claude: Option<&(PathBuf, PathBuf, String)>) -> usize {
    0
}

#[cfg(target_os = "macos")]
pub fn backup_count() -> usize {
    backup_count_for_detected_claude(detect_claude().as_ref())
}

#[cfg(windows)]
pub fn backup_count() -> usize {
    backup_count_for_detected_claude(detect_claude().as_ref())
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn backup_count() -> usize {
    0
}

#[cfg(target_os = "macos")]
pub fn config_library_paths() -> Vec<PathBuf> {
    user_home()
        .map(|home| vec![home.join("Library/Application Support/Claude-3p/configLibrary")])
        .unwrap_or_default()
}

#[cfg(windows)]
pub fn config_library_paths() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(roaming) = dirs::config_dir() {
        out.push(roaming.join("Claude-3p").join("configLibrary"));
    }
    if let Some(local) = dirs::data_local_dir() {
        out.push(local.join("Claude-3p").join("configLibrary"));
    }
    out
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn config_library_paths() -> Vec<PathBuf> {
    Vec::new()
}

#[cfg(target_os = "macos")]
pub fn claude_config_paths() -> Vec<PathBuf> {
    user_home()
        .map(|home| vec![home.join("Library/Application Support/Claude/config.json")])
        .unwrap_or_default()
}

#[cfg(windows)]
pub fn claude_config_paths() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(roaming) = dirs::config_dir() {
        out.push(roaming.join("Claude").join("config.json"));
        out.push(roaming.join("Claude-3p").join("config.json"));
    }
    out
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn claude_config_paths() -> Vec<PathBuf> {
    Vec::new()
}

#[cfg(target_os = "macos")]
pub fn cc_switch_skills_dir() -> Option<PathBuf> {
    user_home().ok().map(|home| home.join(".cc-switch/skills"))
}

#[cfg(windows)]
pub fn cc_switch_skills_dir() -> Option<PathBuf> {
    user_home()
        .ok()
        .map(|home| home.join(".cc-switch").join("skills"))
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn cc_switch_skills_dir() -> Option<PathBuf> {
    None
}

#[cfg(target_os = "macos")]
pub fn skills_plugin_root() -> Option<PathBuf> {
    let base = user_home()
        .ok()?
        .join("Library/Application Support/Claude-3p/local-agent-mode-sessions/skills-plugin");
    find_skills_plugin_root(&base)
}

#[cfg(windows)]
pub fn skills_plugin_root() -> Option<PathBuf> {
    let base = dirs::data_local_dir()?
        .join("Claude-3p")
        .join("local-agent-mode-sessions")
        .join("skills-plugin");
    find_skills_plugin_root(&base)
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn skills_plugin_root() -> Option<PathBuf> {
    None
}

#[cfg(target_os = "macos")]
fn quit_claude(logger: &dyn LogSink) {
    logger.info("正在请求 Claude Desktop 退出。");
    let _ = run_command(
        {
            let mut cmd = Command::new("osascript");
            cmd.arg("-e").arg(r#"tell application "Claude" to quit"#);
            cmd
        },
        logger,
        "关闭 Claude Desktop",
    );
}

#[cfg(windows)]
fn quit_claude(logger: &dyn LogSink) {
    logger.info("正在强制关闭 Claude Desktop 进程。");
    let _ = run_command(
        {
            let mut cmd = Command::new("taskkill");
            cmd.args(["/IM", "Claude.exe", "/F"]);
            cmd
        },
        logger,
        "关闭 Claude Desktop",
    );
}

#[cfg(not(any(target_os = "macos", windows)))]
fn quit_claude(_logger: &dyn LogSink) {}

#[cfg(target_os = "macos")]
fn launch_claude(path: &Path, logger: &dyn LogSink) {
    let _ = run_command(
        {
            let mut cmd = Command::new("open");
            cmd.arg("-a").arg(path);
            cmd
        },
        logger,
        "启动 Claude Desktop",
    );
}

#[cfg(windows)]
fn launch_claude(app: &Path, logger: &dyn LogSink) {
    let exe = [
        "Claude.exe",
        "claude.exe",
        r"app\Claude.exe",
        r"app\claude.exe",
    ]
    .iter()
    .map(|name| app.join(name))
    .find(|path| path.is_file());
    if let Some(exe) = exe {
        let mut cmd = Command::new(exe);
        hide_command_window(&mut cmd);
        let _ = cmd.spawn();
        logger.info("已启动 Claude Desktop");
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
fn launch_claude(_app: &Path, _logger: &dyn LogSink) {}

#[cfg(target_os = "macos")]
fn macos_backup_candidates() -> Result<Vec<PathBuf>> {
    let mut backups: Vec<PathBuf> = fs::read_dir("/Applications")?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_dir()
                && path
                    .file_name()
                    .and_then(OsStr::to_str)
                    .is_some_and(|name| name.starts_with("Claude.backup-before-zh-CN-"))
        })
        .collect();
    backups.sort();
    Ok(backups)
}

#[cfg(target_os = "macos")]
fn macos_entitlements(path: &Path) -> Result<Option<plist::Dictionary>> {
    let output = Command::new("codesign")
        .arg("-d")
        .arg("--entitlements")
        .arg(":-")
        .arg("--xml")
        .arg(path)
        .output()?;
    if output.stdout.is_empty() {
        return Ok(None);
    }
    let value: plist::Value = plist::from_bytes(&output.stdout)?;
    match value {
        plist::Value::Dictionary(dict) => Ok(Some(dict)),
        _ => Ok(None),
    }
}

#[cfg(target_os = "macos")]
fn macos_has_entitlement(path: &Path, key: &str) -> bool {
    macos_entitlements(path)
        .ok()
        .flatten()
        .is_some_and(|ents| ents.contains_key(key))
}

#[cfg(target_os = "macos")]
fn macos_patch_source(app: &Path, logger: &dyn LogSink) -> Result<PathBuf> {
    const REQUIRED_ENTITLEMENT: &str = "com.apple.security.virtualization";
    if macos_has_entitlement(app, REQUIRED_ENTITLEMENT) {
        return Ok(app.to_path_buf());
    }

    logger.warn(
        "当前 Claude.app 缺少 virtualization entitlement，可能已经被粗签名破坏；尝试改用官方备份作为补丁源。",
    );
    for backup in macos_backup_candidates()? {
        if macos_has_entitlement(&backup, REQUIRED_ENTITLEMENT) {
            logger.info(format!("使用现有官方备份作为补丁源: {}", backup.display()));
            return Ok(backup);
        }
    }
    err("当前 Claude.app 缺少必要 entitlement，且没有找到可用官方备份。请先恢复或重装官方 Claude.app。")
}

#[cfg(target_os = "macos")]
fn copy_macos_app_to_temp(source: &Path, target: &Path, logger: &dyn LogSink) -> Result<()> {
    let mut cp = Command::new("cp");
    cp.args(["-cR"]).arg(source).arg(target);
    match run_command(cp, logger, "快速克隆 Claude.app 到临时目录") {
        Ok(_) => Ok(()),
        Err(error) => {
            logger.warn(format!("快速克隆失败，回退 ditto 完整复制: {error}"));
            if target.exists() {
                remove_path(target)?;
            }
            run_command(
                {
                    let mut cmd = Command::new("ditto");
                    cmd.arg(source).arg(target);
                    cmd
                },
                logger,
                "复制 Claude.app 到临时目录",
            )?;
            Ok(())
        }
    }
}

#[cfg(target_os = "macos")]
fn strip_and_augment_entitlements(ents: &mut plist::Dictionary) {
    ents.remove("com.apple.application-identifier");
    ents.remove("com.apple.developer.team-identifier");
    ents.remove("keychain-access-groups");
    ents.insert(
        "com.apple.security.cs.disable-library-validation".to_string(),
        plist::Value::Boolean(true),
    );
}

#[cfg(target_os = "macos")]
fn sign_macos_path(path: &Path) -> Result<()> {
    let mut command = Command::new("codesign");
    command.args([
        "--force",
        "--sign",
        "-",
        "--options",
        "runtime",
        "--preserve-metadata=identifier,flags",
    ]);

    let entitlement_path = if let Some(mut ents) = macos_entitlements(path)? {
        strip_and_augment_entitlements(&mut ents);
        let path = env::temp_dir().join(format!(
            "claude-zh-cn-entitlements-{}.plist",
            Uuid::new_v4()
        ));
        plist::Value::Dictionary(ents).to_file_xml(&path)?;
        command.arg("--entitlements").arg(&path);
        Some(path)
    } else {
        None
    };

    command.arg(path);
    let output = command
        .stderr(Stdio::piped())
        .stdout(Stdio::piped())
        .output()?;
    if let Some(path) = entitlement_path {
        let _ = fs::remove_file(path);
    }
    if !output.status.success() {
        let mut text = String::new();
        text.push_str(&String::from_utf8_lossy(&output.stdout));
        text.push_str(&String::from_utf8_lossy(&output.stderr));
        return err(format!("codesign 失败: {}\n{text}", path.display()));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn macos_path_depth(path: &Path) -> usize {
    path.components().count()
}

#[cfg(target_os = "macos")]
fn is_macos_nested_bundle(path: &Path) -> bool {
    let Some(ext) = path.extension().and_then(OsStr::to_str) else {
        return false;
    };
    matches!(ext, "app" | "framework" | "bundle" | "xpc")
}

#[cfg(target_os = "macos")]
fn is_macos_signable_file(path: &Path) -> bool {
    if path.is_symlink() || !path.is_file() {
        return false;
    }
    if path
        .extension()
        .and_then(OsStr::to_str)
        .is_some_and(|ext| matches!(ext, "dylib" | "node" | "so"))
    {
        return true;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        return fs::metadata(path)
            .map(|meta| meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false);
    }
    #[allow(unreachable_code)]
    false
}

#[cfg(target_os = "macos")]
fn resign_macos_app(app: &Path, logger: &dyn LogSink) -> Result<()> {
    let started = Instant::now();
    let contents = app.join("Contents");
    logger.info("开始扫描 Claude.app 内部可签名文件。");

    let mut file_targets = Vec::new();
    let mut bundle_targets = Vec::new();
    for entry in WalkDir::new(&contents).follow_links(false) {
        let entry = entry?;
        let path = entry.path();
        if entry.file_type().is_dir() {
            if is_macos_nested_bundle(path) {
                bundle_targets.push(path.to_path_buf());
            }
        } else if entry.file_type().is_file() && is_macos_signable_file(path) {
            file_targets.push(path.to_path_buf());
        }
    }

    file_targets.sort_by_key(|path| std::cmp::Reverse(macos_path_depth(path)));
    bundle_targets.sort_by_key(|path| std::cmp::Reverse(macos_path_depth(path)));
    logger.info(format!(
        "需要重签名 {} 个可执行文件、{} 个嵌套 bundle。",
        file_targets.len(),
        bundle_targets.len()
    ));

    for (index, path) in file_targets.iter().enumerate() {
        sign_macos_path(path)?;
        let done = index + 1;
        if done % 25 == 0 || done == file_targets.len() {
            logger.info(format!("已重签名可执行文件: {done}/{}", file_targets.len()));
        }
    }
    for (index, path) in bundle_targets.iter().enumerate() {
        sign_macos_path(path)?;
        let done = index + 1;
        if done % 10 == 0 || done == bundle_targets.len() {
            logger.info(format!(
                "已重签名嵌套 bundle: {done}/{}",
                bundle_targets.len()
            ));
        }
    }
    sign_macos_path(app)?;
    logger.info(format!(
        "Claude.app 重签名完成，用时 {} 秒。",
        started.elapsed().as_secs()
    ));
    Ok(())
}

#[cfg(target_os = "macos")]
fn verify_macos_app_signature(app: &Path, logger: &dyn LogSink) -> Result<()> {
    run_command(
        {
            let mut cmd = Command::new("codesign");
            cmd.args(["--verify", "--deep", "--strict", "--verbose=2"]);
            cmd.arg(app);
            cmd
        },
        logger,
        "验证 Claude.app 签名",
    )?;
    if macos_has_entitlement(app, "com.apple.security.virtualization") {
        logger.info("已确认保留 virtualization entitlement。");
    } else {
        return err("重签名后缺少 virtualization entitlement。");
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn platform_install_patch(
    resources: &Path,
    req: &InstallRequest,
    logger: &dyn LogSink,
) -> Result<()> {
    let (app, _resources_path, _) = detect_claude()
        .ok_or_else(|| CoreError::Message("未找到 /Applications/Claude.app。".to_string()))?;
    logger.info(format!("检测到 Claude.app: {}", app.display()));
    let source_app = macos_patch_source(&app, logger)?;
    if source_app != app {
        logger.info(format!("当前安装将从备份源复制: {}", source_app.display()));
    }
    if req.dry_run {
        logger.info("dry-run：不会关闭 Claude，也不会替换 /Applications/Claude.app。");
    } else {
        quit_claude(logger);
    }
    let tmp_root = env::temp_dir().join(format!(
        "claude-zh-cn-rs-{}",
        Local::now().format("%Y%m%d-%H%M%S")
    ));
    fs::create_dir_all(&tmp_root)?;
    let patched_app = tmp_root.join("Claude.app");
    logger.info(format!("临时工作目录: {}", tmp_root.display()));
    logger.info(format!(
        "正在复制 Claude.app 到临时目录: {}",
        patched_app.display()
    ));
    if patched_app.exists() {
        logger.info("临时 Claude.app 已存在，先清理旧副本。");
        remove_path(&patched_app)?;
    }
    copy_macos_app_to_temp(&source_app, &patched_app, logger)?;
    let patched_resources = patched_app.join("Contents/Resources");
    logger.info(format!(
        "开始写入中文资源和 app.asar 补丁: {}",
        patched_resources.display()
    ));
    install_into_resources(
        InstallPaths {
            source_resources: resources,
            target_resources: &patched_resources,
            mac_app_root: Some(&patched_app),
        },
        &req.language,
        &req.mode,
        None,
        logger,
    )?;
    logger.info("中文资源和 app.asar 补丁已写入临时 Claude.app。");
    logger.info("开始保留 entitlements 重签名临时 Claude.app。");
    resign_macos_app(&patched_app, logger)?;
    verify_macos_app_signature(&patched_app, logger)?;
    let _ = run_command(
        {
            let mut cmd = Command::new("xattr");
            cmd.args(["-dr", "com.apple.quarantine"]);
            cmd.arg(&patched_app);
            cmd
        },
        logger,
        "清理 quarantine 属性",
    );
    if req.dry_run {
        logger.info(format!(
            "dry-run 完成，临时 app 保留在: {}",
            patched_app.display()
        ));
        return Ok(());
    }
    logger.info("开始写入 Claude 语言配置。");
    for config in claude_config_paths() {
        set_config_locale(&config, &req.language, logger)?;
    }
    let backup = app.with_file_name(format!(
        "Claude.backup-before-zh-CN-{}.app",
        Local::now().format("%Y%m%d-%H%M%S")
    ));
    logger.info(format!(
        "准备替换正式 Claude.app，原始应用将备份到: {}",
        backup.display()
    ));
    fs::rename(&app, &backup)?;
    logger.info("原始 Claude.app 已移入备份。");
    fs::rename(&patched_app, &app)?;
    logger.info(format!("补丁版 Claude.app 已安装到: {}", app.display()));
    logger.info(format!("已备份原始 Claude.app: {}", backup.display()));
    if req.launch_after {
        launch_claude(&app, logger);
    }
    Ok(())
}

#[cfg(windows)]
fn platform_install_patch(
    resources: &Path,
    req: &InstallRequest,
    logger: &dyn LogSink,
) -> Result<()> {
    let (app, target_resources, _) =
        detect_claude().ok_or_else(|| CoreError::Message("未找到 Claude Desktop。".to_string()))?;
    logger.info(format!("检测到 Claude Desktop: {}", app.display()));
    logger.info(format!("目标 resources: {}", target_resources.display()));
    if req.dry_run {
        logger.info("dry-run：复制 resources 到临时目录验证，不会修改真实 Claude 安装。");
        let tmp_root = env::temp_dir().join(format!(
            "claude-zh-cn-rs-win-{}",
            Local::now().format("%Y%m%d-%H%M%S")
        ));
        let temp_resources = tmp_root.join("resources");
        logger.info(format!(
            "正在复制 resources 到临时目录: {}",
            temp_resources.display()
        ));
        copy_dir_recursive(&target_resources, &temp_resources)?;
        logger.info("临时 resources 复制完成，开始验证补丁写入。");
        install_into_resources(
            InstallPaths {
                source_resources: resources,
                target_resources: &temp_resources,
                mac_app_root: None,
            },
            &req.language,
            &req.mode,
            None,
            logger,
        )?;
        logger.info(format!(
            "dry-run 完成，临时 resources 保留在: {}",
            temp_resources.display()
        ));
        return Ok(());
    }
    quit_claude(logger);
    let backup_base = target_resources
        .join(".zh-cn-backups")
        .join(Local::now().format("%Y%m%d-%H%M%S").to_string());
    logger.info(format!("Windows 资源备份目录: {}", backup_base.display()));
    let backup = |path: &Path| -> Result<()> {
        if !path.exists() {
            return Ok(());
        }
        let rel = path.strip_prefix(&target_resources).unwrap_or(path);
        copy_file(path, &backup_base.join(rel))
    };
    install_into_resources(
        InstallPaths {
            source_resources: resources,
            target_resources: &target_resources,
            mac_app_root: None,
        },
        &req.language,
        &req.mode,
        Some(&backup),
        logger,
    )?;
    logger.info("Windows resources 补丁写入完成。");
    if req.mode != "safe" {
        logger.info("开始同步 Windows Claude.exe app.asar 完整性标记。");
        sync_windows_exe_asar_integrity(&target_resources, logger)?;
    }
    logger.info("开始写入 Claude 语言配置。");
    for config in claude_config_paths() {
        set_config_locale(&config, &req.language, logger)?;
    }
    save_patched_version(&app, &req.mode, &req.language, logger)?;
    register_update_watcher(logger)?;
    if req.launch_after {
        launch_claude(&app, logger);
    }
    Ok(())
}

#[cfg(windows)]
fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    if dst.exists() {
        remove_path(dst)?;
    }
    fs::create_dir_all(dst)?;
    for entry in WalkDir::new(src) {
        let entry = entry?;
        let rel = entry.path().strip_prefix(src).unwrap();
        let target = dst.join(rel);
        if entry.file_type().is_dir() {
            fs::create_dir_all(&target)?;
        } else if entry.file_type().is_file() {
            copy_file(entry.path(), &target)?;
        }
    }
    Ok(())
}

#[cfg(not(any(target_os = "macos", windows)))]
fn platform_install_patch(
    _resources: &Path,
    _req: &InstallRequest,
    _logger: &dyn LogSink,
) -> Result<()> {
    err("unsupported platform")
}

#[cfg(target_os = "macos")]
fn platform_restore_patch(logger: &dyn LogSink) -> Result<()> {
    let app = PathBuf::from("/Applications/Claude.app");
    logger.info("正在查找 macOS Claude.app 备份。");
    let mut backups: Vec<PathBuf> = fs::read_dir("/Applications")?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_dir()
                && path
                    .file_name()
                    .and_then(OsStr::to_str)
                    .is_some_and(|name| name.starts_with("Claude.backup-before-zh-CN-"))
        })
        .collect();
    backups.sort();
    let Some(backup) = backups.first().cloned() else {
        return err("没有找到可恢复的 Claude 备份。");
    };
    logger.info(format!("将恢复备份: {}", backup.display()));
    quit_claude(logger);
    let current_tmp = app.with_file_name(format!(
        "Claude.restore-current-{}.app",
        Local::now().format("%Y%m%d-%H%M%S")
    ));
    if app.exists() {
        logger.info(format!(
            "当前 Claude.app 临时移动到: {}",
            current_tmp.display()
        ));
        fs::rename(&app, &current_tmp)?;
    }
    fs::rename(&backup, &app)?;
    logger.info(format!("官方 Claude.app 已恢复到: {}", app.display()));
    if current_tmp.exists() {
        logger.info("正在清理恢复前的补丁版 Claude.app。");
        remove_path(&current_tmp)?;
    }
    for extra in backups.into_iter().skip(1) {
        logger.info(format!("正在清理旧备份: {}", extra.display()));
        let _ = remove_path(&extra);
    }
    logger.info("正在恢复英文语言配置。");
    for config in claude_config_paths() {
        set_config_locale(&config, "en-US", logger)?;
    }
    logger.info("macOS 恢复完成。");
    Ok(())
}

#[cfg(windows)]
fn platform_restore_patch(logger: &dyn LogSink) -> Result<()> {
    let (_, resources, _) =
        detect_claude().ok_or_else(|| CoreError::Message("未找到 Claude Desktop。".to_string()))?;
    logger.info(format!(
        "Windows 恢复目标 resources: {}",
        resources.display()
    ));
    quit_claude(logger);
    restore_windows_backup(&resources, logger)?;
    logger.info("正在删除中文语言资源文件。");
    remove_language_files(&resources)?;
    unregister_language(&resources, logger)?;
    logger.info("正在恢复英文语言配置。");
    for config in claude_config_paths() {
        set_config_locale(&config, "en-US", logger)?;
    }
    let _ = unregister_update_watcher(logger);
    logger.info("Windows 恢复完成。");
    Ok(())
}

#[cfg(not(any(target_os = "macos", windows)))]
fn platform_restore_patch(_logger: &dyn LogSink) -> Result<()> {
    err("unsupported platform")
}

#[cfg(windows)]
fn restore_windows_backup(resources: &Path, logger: &dyn LogSink) -> Result<()> {
    let root = resources.join(".zh-cn-backups");
    logger.info(format!("正在查找 Windows 资源备份: {}", root.display()));
    let mut backups: Vec<PathBuf> = fs::read_dir(&root)?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect();
    backups.sort();
    let Some(backup) = backups.first() else {
        logger.warn("没有找到 Windows 备份，跳过 bundle 恢复。");
        return Ok(());
    };
    logger.info(format!("将恢复 Windows 资源备份: {}", backup.display()));
    for entry in WalkDir::new(backup) {
        let entry = entry?;
        if !entry.file_type().is_file() {
            continue;
        }
        let rel = entry.path().strip_prefix(backup).unwrap();
        copy_file(entry.path(), &resources.join(rel))?;
        logger.info(format!("已恢复: {}", rel.display()));
    }
    Ok(())
}

#[cfg(windows)]
fn sync_windows_exe_asar_integrity(resources: &Path, logger: &dyn LogSink) -> Result<()> {
    let app = resources
        .parent()
        .ok_or_else(|| CoreError::Message("resources 路径无父目录。".to_string()))?;
    let exe = [app.join("Claude.exe"), app.join("claude.exe")]
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| CoreError::Message("未找到 Claude.exe。".to_string()))?;
    let header_hash = asar_header_hash(&resources.join("app.asar"))?;
    let marker = br#"resources\\app.asar","alg":"SHA256","value":""#;
    let mut data = fs::read(&exe)?;
    let pos = data
        .windows(marker.len())
        .position(|window| window == marker)
        .ok_or_else(|| CoreError::Message("未找到 Claude.exe app.asar 完整性标记。".to_string()))?;
    let hash_start = pos + marker.len();
    if hash_start + 64 > data.len() {
        return err("Claude.exe app.asar 完整性标记边界无效。");
    }
    data[hash_start..hash_start + 64].copy_from_slice(header_hash.as_bytes());
    fs::write(&exe, data)?;
    logger.info("已同步 Claude.exe app.asar 完整性哈希");
    Ok(())
}

#[cfg(windows)]
fn save_patched_version(
    app: &Path,
    mode: &str,
    language: &str,
    logger: &dyn LogSink,
) -> Result<()> {
    let Some(local) = dirs::data_local_dir() else {
        return Ok(());
    };
    let dir = local.join("ClaudeDesktopZhCn");
    fs::create_dir_all(&dir)?;
    let exe = env::current_exe().ok();
    write_json(
        &dir.join("patched-version.json"),
        &patched_version_record(app, mode, language, exe.as_deref()),
    )?;
    logger.info("已记录补丁版本");
    Ok(())
}

#[cfg(windows)]
fn register_update_watcher(logger: &dyn LogSink) -> Result<()> {
    let exe = env::current_exe()?;
    let task = format!("\"{}\" --cli-action watch-once", exe.display());
    let _ = run_command(
        {
            let mut cmd = Command::new("schtasks");
            cmd.args([
                "/Create",
                "/F",
                "/SC",
                "MINUTE",
                "/MO",
                "30",
                "/TN",
                WATCHER_TASK,
                "/TR",
                &task,
            ]);
            cmd
        },
        logger,
        "注册更新守护计划任务",
    );
    Ok(())
}

#[cfg(windows)]
fn unregister_update_watcher(logger: &dyn LogSink) -> Result<()> {
    let _ = run_command(
        {
            let mut cmd = Command::new("schtasks");
            cmd.args(["/Delete", "/F", "/TN", WATCHER_TASK]);
            cmd
        },
        logger,
        "移除更新守护计划任务",
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    #[cfg(windows)]
    #[test]
    fn windows_detection_helpers_exist() {
        let _ = super::detect_windows_claude_in_localappdata();
        let _ = super::detect_windows_claude_in_windowsapps();
    }
}
