use chrono::Local;
use serde_json::{json, Value};
use std::ffi::OsStr;
use std::path::Path;

pub fn patched_version_record(
    app: &Path,
    mode: &str,
    language: &str,
    gui_exe: Option<&Path>,
) -> Value {
    let version = app
        .file_name()
        .and_then(OsStr::to_str)
        .and_then(|name| name.strip_prefix("app-"))
        .unwrap_or("unknown");
    json!({
        "version": version,
        "installPath": app,
        "patchTime": Local::now().to_rfc3339(),
        "patchMode": mode,
        "language": language,
        "guiExe": gui_exe.map(|path| path.display().to_string())
    })
}
