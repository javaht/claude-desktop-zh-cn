use claude_zh_core::{err, LogEvent, LogSink, LogSinkExt, Result};
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::{
    fs,
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
};
#[cfg(windows)]
use windows::Win32::Globalization::{MultiByteToWideChar, CP_OEMCP, MULTI_BYTE_TO_WIDE_CHAR_FLAGS};

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
