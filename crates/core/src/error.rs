use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("{0}")]
    Message(String),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("plist error: {0}")]
    Plist(#[from] plist::Error),
    #[error("regex error: {0}")]
    Regex(#[from] regex::Error),
    #[error("walkdir error: {0}")]
    Walkdir(#[from] walkdir::Error),
}

pub type Result<T> = std::result::Result<T, CoreError>;

pub fn err<T>(message: impl Into<String>) -> Result<T> {
    Err(CoreError::Message(message.into()))
}
