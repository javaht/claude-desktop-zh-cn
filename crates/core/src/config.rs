use crate::{
    error::Result,
    fs_utils::{load_json_object_or_backup, write_json},
    logging::LogSink,
};
use serde_json::Value;
use std::path::Path;

pub fn set_config_locale(path: &Path, lang: &str, logger: &dyn LogSink) -> Result<()> {
    let mut data = load_json_object_or_backup(path, logger)?;
    data.insert("locale".to_string(), Value::String(lang.to_string()));
    write_json(path, &Value::Object(data))?;
    Ok(())
}
