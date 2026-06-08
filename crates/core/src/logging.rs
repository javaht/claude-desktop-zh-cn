use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogEvent {
    pub level: String,
    pub message: String,
}

pub trait LogSink {
    fn log(&self, level: &str, message: &str);
}

pub trait LogSinkExt: LogSink {
    fn info(&self, message: impl AsRef<str>) {
        self.log("info", message.as_ref());
    }

    fn warn(&self, message: impl AsRef<str>) {
        self.log("warn", message.as_ref());
    }

    fn error(&self, message: impl AsRef<str>) {
        self.log("error", message.as_ref());
    }
}

impl<T: LogSink + ?Sized> LogSinkExt for T {}

#[derive(Clone, Copy)]
pub struct StdoutLogger;

impl LogSink for StdoutLogger {
    fn log(&self, level: &str, message: &str) {
        println!("[{level}] {message}");
    }
}

#[derive(Clone, Copy)]
pub struct NoopLogger;

impl LogSink for NoopLogger {
    fn log(&self, _level: &str, _message: &str) {}
}
