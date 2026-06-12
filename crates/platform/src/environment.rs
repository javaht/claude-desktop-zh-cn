use claude_zh_core::{read_json, EnvironmentReport};
use std::{env, fs, path::PathBuf, process::Command};
#[cfg(windows)]
use std::{ffi::OsStr, path::Path, process::Stdio};

#[cfg(windows)]
use crate::logging::hide_command_window;
use crate::{
    auto_update::auto_updates_enabled,
    paths::{cc_switch_skills_dir, claude_config_paths, skills_plugin_root},
    resources::resolve_resources,
};

pub fn detect_environment(resources_dir: Option<PathBuf>) -> EnvironmentReport {
    let resources = resolve_resources(resources_dir).ok();
    let resource_issues = resources
        .as_ref()
        .map(|path| claude_zh_core::verify_language_resource_files(path))
        .unwrap_or_else(|| vec!["未找到 resources 目录。".to_string()]);
    let claude = detect_claude();
    let is_admin = is_admin();
    let backup_count = backup_count_for_detected_claude(claude.as_ref());
    let mut warnings = Vec::new();
    if claude.is_none() {
        warnings.push("未检测到 Claude Desktop 安装。".to_string());
    }
    if !resource_issues.is_empty() {
        warnings.push("随包资源检查未通过。".to_string());
    }
    EnvironmentReport {
        platform: platform_name().to_string(),
        arch: env::consts::ARCH.to_string(),
        resources_dir: resources.as_ref().map(|path| path.display().to_string()),
        resources_ok: resource_issues.is_empty(),
        resource_issues,
        claude_path: claude.as_ref().map(|(app, _, _)| app.display().to_string()),
        resources_path: claude
            .as_ref()
            .map(|(_, resources, _)| resources.display().to_string()),
        install_kind: claude.as_ref().map(|(_, _, kind)| kind.clone()),
        is_admin,
        needs_admin: claude.is_some() && !is_admin,
        current_locale: current_locale(),
        backup_count,
        cc_switch_skills_dir: cc_switch_skills_dir().map(|path| path.display().to_string()),
        skills_plugin_root: skills_plugin_root().map(|path| path.display().to_string()),
        auto_updates_enabled: auto_updates_enabled(),
        warnings,
    }
}

#[cfg(target_os = "macos")]
pub fn platform_name() -> &'static str {
    "macOS"
}

#[cfg(windows)]
pub fn platform_name() -> &'static str {
    "Windows"
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn platform_name() -> &'static str {
    "Unsupported"
}

#[cfg(target_os = "macos")]
pub fn is_admin() -> bool {
    Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .is_some_and(|uid| uid.trim() == "0")
}

#[cfg(windows)]
pub fn is_admin() -> bool {
    let mut cmd = Command::new("cmd");
    hide_command_window(&mut cmd);
    cmd.args(["/C", "net", "session"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn is_admin() -> bool {
    false
}

#[cfg(target_os = "macos")]
pub fn detect_claude() -> Option<(PathBuf, PathBuf, String)> {
    let app = PathBuf::from("/Applications/Claude.app");
    let resources = app.join("Contents/Resources");
    if resources.is_dir() {
        Some((app, resources, "Applications".to_string()))
    } else {
        None
    }
}

#[cfg(windows)]
pub fn detect_claude() -> Option<(PathBuf, PathBuf, String)> {
    detect_windows_claude_in_localappdata()
        .or_else(detect_windows_claude_in_windowsapps)
        .or_else(detect_windows_claude_from_registry)
}

#[cfg(windows)]
fn windows_claude_version_key(path: &Path, prefix: &str) -> Vec<u32> {
    path.file_name()
        .and_then(OsStr::to_str)
        .and_then(|name| name.strip_prefix(prefix))
        .unwrap_or_default()
        .split(|ch: char| !ch.is_ascii_digit())
        .filter_map(|part| {
            if part.is_empty() {
                None
            } else {
                part.parse::<u32>().ok()
            }
        })
        .collect()
}

#[cfg(windows)]
fn compare_windows_claude_paths(prefix: &str, a: &Path, b: &Path) -> std::cmp::Ordering {
    windows_claude_version_key(b, prefix)
        .cmp(&windows_claude_version_key(a, prefix))
        .then_with(|| {
            let a_name = a.file_name().map(|name| name.to_string_lossy());
            let b_name = b.file_name().map(|name| name.to_string_lossy());
            b_name.cmp(&a_name)
        })
}

#[cfg(windows)]
pub fn detect_windows_claude_in_localappdata() -> Option<(PathBuf, PathBuf, String)> {
    let base = dirs::data_local_dir()?.join("AnthropicClaude");
    let mut apps: Vec<PathBuf> = fs::read_dir(base)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .filter(|p| {
            p.is_dir()
                && p.file_name()
                    .and_then(OsStr::to_str)
                    .is_some_and(|name| name.starts_with("app-"))
        })
        .collect();
    apps.sort_by(|a, b| compare_windows_claude_paths("app-", a, b));
    for app in apps {
        let resources = app.join("resources");
        if resources.is_dir() {
            return Some((app, resources, "Unpackaged".to_string()));
        }
    }
    None
}

#[cfg(windows)]
pub fn detect_windows_claude_in_windowsapps() -> Option<(PathBuf, PathBuf, String)> {
    let windows_apps = PathBuf::from(r"C:\Program Files\WindowsApps");
    let mut apps: Vec<PathBuf> = fs::read_dir(windows_apps)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .filter(|p| {
            p.is_dir()
                && p.file_name()
                    .and_then(OsStr::to_str)
                    .is_some_and(|name| name.starts_with("Claude_"))
        })
        .collect();
    apps.sort_by(|a, b| compare_windows_claude_paths("Claude_", a, b));
    for app in apps {
        let resources = app.join("app").join("resources");
        if resources.is_dir() {
            return Some((app, resources, "AppX".to_string()));
        }
    }
    None
}

#[cfg(windows)]
fn detect_windows_claude_from_registry() -> Option<(PathBuf, PathBuf, String)> {
    let mut cmd = Command::new("reg");
    cmd.args([
        "query",
        r"HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages",
    ]);
    hide_command_window(&mut cmd);
    cmd.stdout(Stdio::piped()).stderr(Stdio::null());
    let output = cmd.output().ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut entries: Vec<String> = Vec::new();
    for line in stdout.lines() {
        let trimmed = line.trim();
        if let Some(name) = trimmed.rsplit('\\').next() {
            if name.starts_with("Claude_") {
                entries.push(name.to_string());
            }
        }
    }
    entries.sort_by(|a, b| {
        compare_windows_claude_paths("Claude_", &PathBuf::from(b), &PathBuf::from(a))
    });
    for name in entries {
        let key = format!(
            r"HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages\{}",
            name
        );
        let mut detail_cmd = Command::new("reg");
        detail_cmd.args(["query", &key, "/v", "PackageRootFolder"]);
        hide_command_window(&mut detail_cmd);
        detail_cmd.stdout(Stdio::piped()).stderr(Stdio::null());
        let detail = detail_cmd.output().ok()?;
        let detail_stdout = String::from_utf8_lossy(&detail.stdout);
        for dline in detail_stdout.lines() {
            if let Some(pos) = dline.find("PackageRootFolder") {
                let rest = dline[pos + "PackageRootFolder".len()..].trim();
                let parts: Vec<&str> = rest.splitn(3, char::is_whitespace).collect();
                if let Some(path_str) = parts.last() {
                    let root = PathBuf::from(path_str.trim());
                    let resources = root.join("app").join("resources");
                    if resources.is_dir() {
                        return Some((root, resources, "AppX".to_string()));
                    }
                }
            }
        }
    }
    None
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn detect_claude() -> Option<(PathBuf, PathBuf, String)> {
    None
}

pub fn current_locale() -> Option<String> {
    claude_config_paths().into_iter().find_map(|path| {
        read_json(&path).ok().and_then(|v| {
            v.get("locale")
                .and_then(serde_json::Value::as_str)
                .map(ToOwned::to_owned)
        })
    })
}

#[cfg(target_os = "macos")]
fn backup_count_for_detected_claude(_claude: Option<&(PathBuf, PathBuf, String)>) -> usize {
    fs::read_dir("/Applications")
        .ok()
        .map(|entries| {
            entries
                .flatten()
                .filter(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .starts_with("Claude.backup-before-zh-CN-")
                })
                .count()
        })
        .unwrap_or(0)
}

#[cfg(windows)]
fn backup_count_for_detected_claude(claude: Option<&(PathBuf, PathBuf, String)>) -> usize {
    claude
        .and_then(|(_, resources, _)| fs::read_dir(resources.join(".zh-cn-backups")).ok())
        .map(|entries| {
            entries
                .flatten()
                .filter(|entry| entry.path().is_dir())
                .count()
        })
        .unwrap_or(0)
}

#[cfg(not(any(target_os = "macos", windows)))]
fn backup_count_for_detected_claude(_claude: Option<&(PathBuf, PathBuf, String)>) -> usize {
    0
}

#[cfg(target_os = "macos")]
pub fn backup_count() -> usize {
    backup_count_for_detected_claude(detect_claude().as_ref())
}

#[cfg(windows)]
pub fn backup_count() -> usize {
    backup_count_for_detected_claude(detect_claude().as_ref())
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn backup_count() -> usize {
    0
}
