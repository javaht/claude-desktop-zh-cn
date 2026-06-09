use claude_zh_core::{
    err, write_json, CliRequest, CoreError, LogEvent, LogSink, LogSinkExt, Result,
};
use std::{
    env, fs,
    io::{BufRead, BufReader, Seek, SeekFrom},
    path::Path,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;

use crate::{
    actions::{install_patch, restore_patch, set_auto_updates, sync_cc_switch_skills, unsync_cc_switch_skills},
    logging::{decode_command_output, hide_command_window},
    resources::resolve_resources,
};

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
    install: Option<claude_zh_core::InstallRequest>,
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
            for line in decode_command_output(&output.stdout).lines() {
                if !line.trim().is_empty() {
                    logger.info(line);
                }
            }
            for line in decode_command_output(&output.stderr).lines() {
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
        let script = elevated_command_script(
            Path::new(r"C:\tool\claude-desktop-zh-cn-rs.exe"),
            Path::new(r"C:\Temp\request.json"),
        );

        assert!(script.contains("-PassThru"));
        assert!(script.contains(".WaitForExit()"));
        assert!(script.contains("exit $p.ExitCode"));
        assert!(!script.contains(" -Wait"));
    }
}
