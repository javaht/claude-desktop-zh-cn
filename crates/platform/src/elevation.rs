//! 提权请求与日志桥接模块。
//!
//! 在 Windows 平台上，安装/恢复操作可能需要管理员权限（如修改 WindowsApps 目录）。
//! 本模块通过临时文件 + UAC 提权重新执行子进程来获得权限：
//! - 父进程把请求参数写入 elevation 私有目录下的 JSON 文件，启动提权子进程后等待完成
//! - 子进程读取请求文件，执行操作，把日志事件以 jsonl 格式追加到 log 文件
//! - 父进程通过 `drain_jsonl_log` 增量读取并转发到主 logger
//!
//! `cleanup_stale_elevation_files` 会在启动时清理 elevation 目录下超过 1 小时的残留文件。
//! `write_json_exclusive` 使用 `create_new(true)` 防 TOCTOU。

use claude_zh_core::{
    err, CliRequest, CoreError, LogEvent, LogSink, LogSinkExt, Result,
};
use std::{
    env, fs,
    io::{BufRead, BufReader, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;

#[cfg(windows)]
use crate::logging::hide_command_window;
use crate::{
    actions::{install_patch, restore_patch, sync_cc_switch_skills, unsync_cc_switch_skills},
    auto_update::set_auto_updates,
    resources::resolve_resources,
};

pub fn run_cli_request(request: CliRequest, logger: &dyn LogSink) -> Result<()> {
    match request.action.as_str() {
        "install_patch" => {
            let resources = if let Some(path) = request.resources_path {
                path
            } else {
                resolve_resources(None)?
            };
            let install = request
                .install
                .ok_or_else(|| CoreError::Message("缺少 install 参数。".to_string()))?;
            install_patch(&resources, &install, logger)
        }
        "restore_patch" => {
            let dry_run = request.restore.map(|r| r.dry_run).unwrap_or(false);
            restore_patch(dry_run, logger)
        }
        "set_auto_updates" => {
            let enabled = request
                .enabled
                .ok_or_else(|| CoreError::Message("缺少 enabled 参数。".to_string()))?;
            set_auto_updates(enabled, logger)
        }
        "sync_cc_switch_skills" => sync_cc_switch_skills(logger),
        "unsync_cc_switch_skills" => unsync_cc_switch_skills(logger),
        "watch-once" => {
            logger.info("更新守护 CLI 已启动。");
            Ok(())
        }
        other => err(format!("未知 CLI action: {other}")),
    }
}

fn elevation_dir() -> Result<PathBuf> {
    let base = dirs::data_local_dir()
        .or_else(dirs::config_dir)
        .ok_or_else(|| CoreError::Message("无法确定用户本地数据目录。".to_string()))?;
    let dir = base.join("ClaudeDesktopZhCn").join("elevation");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn write_json_exclusive(path: &Path, value: &serde_json::Value) -> Result<()> {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| {
            CoreError::Message(format!(
                "创建文件失败（可能已存在）: {} — {e}",
                path.display()
            ))
        })?;
    let json = serde_json::to_string_pretty(value)?;
    file.write_all(json.as_bytes())?;
    Ok(())
}

fn cleanup_stale_elevation_files(dir: &Path) {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path
                .extension()
                .is_some_and(|ext| ext == "json" || ext == "jsonl")
            {
                if let Ok(metadata) = path.metadata() {
                    if let Ok(modified) = metadata.modified() {
                        if modified.elapsed().unwrap_or_default() > Duration::from_secs(3600) {
                            let _ = fs::remove_file(&path);
                        }
                    }
                }
            }
        }
    }
}

pub fn run_elevated_cli(
    action: &str,
    install: Option<claude_zh_core::InstallRequest>,
    restore: Option<claude_zh_core::RestoreRequest>,
    enabled: Option<bool>,
    resources_path: Option<&Path>,
    logger: &dyn LogSink,
) -> Result<()> {
    let elev_dir = elevation_dir()?;
    cleanup_stale_elevation_files(&elev_dir);
    let log_path = elev_dir.join(format!("claude-zh-cn-rs-{}.jsonl", Uuid::new_v4()));
    let request = CliRequest {
        action: action.to_string(),
        install,
        restore,
        enabled,
        resources_path: resources_path.map(|p| p.to_path_buf()),
        log_path: Some(log_path.clone()),
    };
    let request_path = elev_dir.join(format!("claude-zh-cn-rs-{}.json", Uuid::new_v4()));
    write_json_exclusive(&request_path, &serde_json::to_value(&request)?)?;
    let exe = env::current_exe()?;
    logger.info(format!("准备提权执行: {action}"));
    logger.info(format!("当前可执行文件: {}", exe.display()));
    logger.info(format!("提权请求文件: {}", request_path.display()));
    logger.info(format!("提权日志文件: {}", log_path.display()));
    if let Some(rp) = resources_path {
        logger.info(format!("随包资源目录: {}", rp.display()));
    }
    if let Some(install) = &request.install {
        logger.info(format!(
            "安装参数: language={}, mode={}, launch_after={}, dry_run={}",
            install.language, install.mode, install.launch_after, install.dry_run
        ));
    }
    if let Some(restore) = &request.restore {
        logger.info(format!("恢复参数: dry_run={}", restore.dry_run));
    }
    logger.info("需要管理员权限，正在请求系统授权。");

    // 提权子进程的所有日志走 jsonl 文件，stdout/stderr 直接丢弃，
    // 避免 OS pipe 填满后 println! 阻塞子进程、而父进程又一直等子进程退出的死锁。
    let mut child = elevated_command(&exe, &request_path)?
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    logger.info("授权流程已提交，正在等待管理员子进程写入日志。");
    let start = Instant::now();
    let mut offset = 0u64;
    let mut next_heartbeat = 5u64;
    loop {
        offset = drain_jsonl_log(&log_path, offset, logger)?;
        if let Some(status) = child.try_wait()? {
            drain_jsonl_log(&log_path, offset, logger)?;
            let _ = fs::remove_file(&request_path);
            if !status.success() {
                let _ = fs::remove_file(&log_path);
                return err(format!("管理员子进程失败，退出码: {status}"));
            }
            logger.info(format!(
                "管理员子进程完成，用时 {} 秒",
                start.elapsed().as_secs()
            ));
            let _ = fs::remove_file(&log_path);
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
    let command = elevated_command_script(exe, request_path);
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
fn elevated_command_script(exe: &Path, request_path: &Path) -> String {
    format!(
        "$p = Start-Process -FilePath {} -ArgumentList @('--cli-file',{}) -Verb RunAs -WindowStyle Hidden -PassThru; $null = $p.WaitForExit(); exit $p.ExitCode",
        powershell_single_quote(&exe.display().to_string()),
        powershell_single_quote(&request_path.display().to_string())
    )
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

#[cfg(all(test, windows))]
mod tests {
    use super::elevated_command_script;
    use std::path::Path;

    #[test]
    fn windows_elevated_command_waits_for_installer_process_only() {
        // The elevated child process uses the built exe filename, which follows the shared package name.
        let script = elevated_command_script(
            Path::new(r"C:\tool\claude-desktop-zh-cn.exe"),
            Path::new(r"C:\Temp\request.json"),
        );

        assert!(script.contains("-PassThru"));
        assert!(script.contains(".WaitForExit()"));
        assert!(script.contains("exit $p.ExitCode"));
        assert!(!script.contains(" -Wait"));
    }
}
