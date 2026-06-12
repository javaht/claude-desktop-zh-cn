use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::{err, Result};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallRequest {
    pub language: String,
    pub mode: String,
    pub launch_after: bool,
    pub dry_run: bool,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreRequest {
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliRequest {
    pub action: String,
    pub install: Option<InstallRequest>,
    #[serde(default)]
    pub restore: Option<RestoreRequest>,
    pub enabled: Option<bool>,
    pub resources_path: Option<PathBuf>,
    pub log_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvironmentReport {
    pub platform: String,
    pub arch: String,
    pub resources_dir: Option<String>,
    pub resources_ok: bool,
    pub resource_issues: Vec<String>,
    pub claude_path: Option<String>,
    pub resources_path: Option<String>,
    pub install_kind: Option<String>,
    pub is_admin: bool,
    pub needs_admin: bool,
    pub current_locale: Option<String>,
    pub backup_count: usize,
    pub cc_switch_skills_dir: Option<String>,
    pub skills_plugin_root: Option<String>,
    pub auto_updates_enabled: Option<bool>,
    pub warnings: Vec<String>,
}

#[derive(Clone)]
pub struct LanguagePack {
    pub frontend: PathBuf,
    pub hardcoded: PathBuf,
    pub desktop: PathBuf,
    pub statsig: PathBuf,
    pub localizable: PathBuf,
}

#[derive(Clone, Copy)]
pub struct InstallPaths<'a> {
    pub source_resources: &'a Path,
    pub target_resources: &'a Path,
    pub mac_app_root: Option<&'a Path>,
}

pub const SUPPORTED_LANGUAGES: &[&str] = &["zh-CN", "zh-TW", "zh-HK"];
pub const SUPPORTED_MODES: &[&str] = &["safe", "official"];

pub fn validate_install_request(req: &InstallRequest) -> Result<()> {
    if !SUPPORTED_LANGUAGES.contains(&req.language.as_str()) {
        return err(format!(
            "不支持的语言: {}（支持: {}）",
            req.language,
            SUPPORTED_LANGUAGES.join(", ")
        ));
    }
    if !SUPPORTED_MODES.contains(&req.mode.as_str()) {
        return err(format!(
            "不支持的模式: {}（支持: {}）",
            req.mode,
            SUPPORTED_MODES.join(", ")
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(language: &str, mode: &str) -> InstallRequest {
        InstallRequest {
            language: language.to_string(),
            mode: mode.to_string(),
            launch_after: false,
            dry_run: false,
        }
    }

    #[test]
    fn validate_install_request_accepts_supported_combos() {
        assert!(validate_install_request(&req("zh-CN", "safe")).is_ok());
        assert!(validate_install_request(&req("zh-TW", "official")).is_ok());
        assert!(validate_install_request(&req("zh-HK", "safe")).is_ok());
    }

    #[test]
    fn validate_install_request_rejects_unsupported_language() {
        assert!(validate_install_request(&req("fr-FR", "safe")).is_err());
        assert!(validate_install_request(&req("en-US", "safe")).is_err());
    }

    #[test]
    fn validate_install_request_rejects_unsupported_mode() {
        assert!(validate_install_request(&req("zh-CN", "install")).is_err());
        assert!(validate_install_request(&req("zh-CN", "uninstall")).is_err());
    }

    #[test]
    fn validate_install_request_rejects_empty() {
        assert!(validate_install_request(&req("", "safe")).is_err());
        assert!(validate_install_request(&req("zh-CN", "")).is_err());
    }
}
