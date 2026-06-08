use crate::{
    error::Result,
    fs_utils::{load_json_object_or_backup, read_json, write_json},
    logging::LogSink,
};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub fn set_config_locale(path: &Path, lang: &str, logger: &dyn LogSink) -> Result<()> {
    let mut data = load_json_object_or_backup(path, logger)?;
    data.insert("locale".to_string(), Value::String(lang.to_string()));
    write_json(path, &Value::Object(data))?;
    Ok(())
}

pub fn config_library_set_auto_updates(
    path: &Path,
    enabled: bool,
    logger: &dyn LogSink,
) -> Result<()> {
    fs::create_dir_all(path)?;
    let meta_path = path.join("_meta.json");
    let mut meta = load_json_object_or_backup(&meta_path, logger)?;
    let config_id = meta
        .get("appliedId")
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| {
            fs::read_dir(path).ok().and_then(|entries| {
                let mut names: Vec<String> = entries
                    .flatten()
                    .filter_map(|entry| {
                        let file_name = entry.file_name().to_string_lossy().to_string();
                        if file_name.ends_with(".json") && file_name != "_meta.json" {
                            Some(file_name.trim_end_matches(".json").to_string())
                        } else {
                            None
                        }
                    })
                    .collect();
                names.sort();
                names.into_iter().next()
            })
        })
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let config_path = path.join(format!("{config_id}.json"));
    let mut config = load_json_object_or_backup(&config_path, logger)?;
    config.insert("disableAutoUpdates".to_string(), Value::Bool(!enabled));
    meta.insert("appliedId".to_string(), Value::String(config_id.clone()));
    let entries = meta
        .entry("entries")
        .or_insert_with(|| Value::Array(Vec::new()));
    if !entries.as_array().is_some_and(|items| {
        items
            .iter()
            .any(|item| item.get("id").and_then(Value::as_str) == Some(config_id.as_str()))
    }) {
        if !entries.is_array() {
            *entries = Value::Array(Vec::new());
        }
        entries
            .as_array_mut()
            .unwrap()
            .push(json!({"id": config_id, "name": "Default"}));
    }
    write_json(&config_path, &Value::Object(config))?;
    write_json(&meta_path, &Value::Object(meta))?;
    Ok(())
}

pub fn auto_updates_enabled(paths: Vec<PathBuf>) -> Option<bool> {
    for path in paths {
        let meta = read_json(&path.join("_meta.json")).ok()?;
        let config_id = meta.get("appliedId").and_then(Value::as_str)?;
        let config = read_json(&path.join(format!("{config_id}.json"))).ok()?;
        return Some(
            !config
                .get("disableAutoUpdates")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        );
    }
    None
}
