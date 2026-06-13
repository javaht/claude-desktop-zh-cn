use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("{0}")]
    Message(String),
    #[error("IO 错误: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON 错误: {0}")]
    Json(#[from] serde_json::Error),
    #[error("plist 错误: {0}")]
    Plist(#[from] plist::Error),
    #[error("正则表达式错误: {0}")]
    Regex(#[from] regex::Error),
    #[error("目录遍历错误: {0}")]
    Walkdir(#[from] walkdir::Error),
}

pub type Result<T> = std::result::Result<T, CoreError>;

pub fn err<T>(message: impl Into<String>) -> Result<T> {
    Err(CoreError::Message(message.into()))
}
