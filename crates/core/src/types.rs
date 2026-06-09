use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallRequest {
    pub language: String,
    pub mode: String,
    pub launch_after: bool,
    pub dry_run: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliRequest {
    pub action: String,
    pub install: Option<InstallRequest>,
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
