use claude_zh_core::{find_skills_plugin_root, CoreError, Result};
use std::path::PathBuf;

pub fn user_home() -> Result<PathBuf> {
    dirs::home_dir().ok_or_else(|| CoreError::Message("无法确定用户目录。".to_string()))
}

#[cfg(target_os = "macos")]
pub fn config_library_paths() -> Vec<PathBuf> {
    user_home()
        .map(|home| vec![home.join("Library/Application Support/Claude-3p/configLibrary")])
        .unwrap_or_default()
}

#[cfg(windows)]
pub fn config_library_paths() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(roaming) = dirs::config_dir() {
        out.push(roaming.join("Claude-3p").join("configLibrary"));
    }
    if let Some(local) = dirs::data_local_dir() {
        out.push(local.join("Claude-3p").join("configLibrary"));
    }
    out
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn config_library_paths() -> Vec<PathBuf> {
    Vec::new()
}

#[cfg(target_os = "macos")]
pub fn claude_config_paths() -> Vec<PathBuf> {
    user_home()
        .map(|home| vec![home.join("Library/Application Support/Claude/config.json")])
        .unwrap_or_default()
}

#[cfg(windows)]
pub fn claude_config_paths() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(roaming) = dirs::config_dir() {
        out.push(roaming.join("Claude").join("config.json"));
        out.push(roaming.join("Claude-3p").join("config.json"));
    }
    out
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn claude_config_paths() -> Vec<PathBuf> {
    Vec::new()
}

#[cfg(target_os = "macos")]
pub fn cc_switch_skills_dir() -> Option<PathBuf> {
    user_home().ok().map(|home| home.join(".cc-switch/skills"))
}

#[cfg(windows)]
pub fn cc_switch_skills_dir() -> Option<PathBuf> {
    user_home()
        .ok()
        .map(|home| home.join(".cc-switch").join("skills"))
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn cc_switch_skills_dir() -> Option<PathBuf> {
    None
}

#[cfg(target_os = "macos")]
pub fn skills_plugin_root() -> Option<PathBuf> {
    let base = user_home()
        .ok()?
        .join("Library/Application Support/Claude-3p/local-agent-mode-sessions/skills-plugin");
    find_skills_plugin_root(&base)
}

#[cfg(windows)]
pub fn skills_plugin_root() -> Option<PathBuf> {
    let base = dirs::data_local_dir()?
        .join("Claude-3p")
        .join("local-agent-mode-sessions")
        .join("skills-plugin");
    find_skills_plugin_root(&base)
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn skills_plugin_root() -> Option<PathBuf> {
    None
}
