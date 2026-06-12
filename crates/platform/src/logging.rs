//! 日志记录工具模块。
//!
//! 提供 `FileLogger`：基于 jsonl 格式的事件日志文件 sink，每行一个 JSON 事件。
//! 在 Windows 平台上，子进程输出可能是 OEM 编码（如 GBK/CP936），本模块在写入前会解码为 UTF-8。
//!
//! `run_command` 是跨平台命令执行 helper，自动捕获 stdout/stderr 并按级别记录到 logger。
//! 在 Windows 上调用 `hide_command_window` 在子进程上设置 `CREATE_NO_WINDOW` 标志，
//! 避免命令行窗口闪烁。

use claude_zh_core::{err, LogEvent, LogSink, LogSinkExt, Result};
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::{
    fs,
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
};
#[cfg(windows)]
use windows::Win32::Globalization::{MultiByteToWideChar, CP_OEMCP, MULTI_BYTE_TO_WIDE_CHAR_FLAGS};

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

/// 当 FileLogger 用于提权子进程时（父进程通过 jsonl 文件读日志），
/// 不应该再向 stdout 打印——父进程已将子进程 stdout 设为 Stdio::null()，
/// 写入只是浪费且会让本地排查日志变得嘈杂。
static FILE_LOGGER_SILENT_STDOUT: AtomicBool = AtomicBool::new(false);

pub fn set_file_logger_silent_stdout(silent: bool) {
    FILE_LOGGER_SILENT_STDOUT.store(silent, Ordering::Relaxed);
}

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
        if !FILE_LOGGER_SILENT_STDOUT.load(Ordering::Relaxed) {
            println!("[{level}] {message}");
        }
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
    text.push_str(&decode_command_output(&output.stdout));
    text.push_str(&decode_command_output(&output.stderr));
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
pub(crate) fn hide_command_window(command: &mut Command) {
    command.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
pub(crate) fn hide_command_window(_command: &mut Command) {}

pub(crate) fn decode_command_output(bytes: &[u8]) -> String {
    if let Ok(text) = std::str::from_utf8(bytes) {
        text.to_string()
    } else {
        decode_platform_command_output(bytes)
    }
}

#[cfg(windows)]
fn decode_platform_command_output(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return String::new();
    }
    unsafe {
        let needed = MultiByteToWideChar(CP_OEMCP, MULTI_BYTE_TO_WIDE_CHAR_FLAGS(0), bytes, None);
        if needed <= 0 {
            return String::from_utf8_lossy(bytes).into_owned();
        }
        let mut wide = vec![0u16; needed as usize];
        let written = MultiByteToWideChar(
            CP_OEMCP,
            MULTI_BYTE_TO_WIDE_CHAR_FLAGS(0),
            bytes,
            Some(&mut wide),
        );
        if written <= 0 {
            String::from_utf8_lossy(bytes).into_owned()
        } else {
            String::from_utf16_lossy(&wide[..written as usize])
        }
    }
}

#[cfg(not(windows))]
fn decode_platform_command_output(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}
