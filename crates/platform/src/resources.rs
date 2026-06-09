use claude_zh_core::{
    copy_file, err, read_json, remove_path, write_json, CoreError, LogSink, LogSinkExt, Result,
};
use serde::{Deserialize, Serialize};
use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};
use uuid::Uuid;
use walkdir::WalkDir;

use crate::logging::run_command;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceReleaseManifest {
    pub repo: String,
    pub release: String,
}

pub fn resource_candidates(tauri_resource_dir: Option<PathBuf>) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(resource_dir) = tauri_resource_dir {
        out.push(resource_dir.join("resources"));
        out.push(resource_dir.join("_up_/_up_/resources"));
        out.push(resource_dir.join("_up_/resources"));
        out.push(resource_dir);
    }
    if let Ok(exe) = env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            out.push(exe_dir.join("resources"));
            out.push(exe_dir.join("_up_/_up_/resources"));
            out.push(exe_dir.join("_up_/resources"));
            out.push(exe_dir.join("../Resources/resources"));
            out.push(exe_dir.join("../Resources"));
            out.push(exe_dir.join("../../../../resources"));
        }
    }
    if let Ok(manifest_dir) = env::var("CARGO_MANIFEST_DIR") {
        out.push(PathBuf::from(manifest_dir).join("../../../resources"));
    }
    if let Ok(current) = env::current_dir() {
        out.push(current.join("resources"));
        out.push(current.join("../resources"));
        out.push(current.join("../../resources"));
        out.push(current.join("../../../resources"));
    }
    out
}

pub fn resolve_resources(tauri_resource_dir: Option<PathBuf>) -> Result<PathBuf> {
    for candidate in resource_candidates(tauri_resource_dir) {
        let marker = candidate.join("frontend-zh-CN.json");
        if marker.is_file() {
            return Ok(candidate.canonicalize().unwrap_or(candidate));
        }
    }
    err("未找到随包 resources 目录。")
}

pub fn resource_release_manifest(
    resources_dir: Option<PathBuf>,
) -> Result<ResourceReleaseManifest> {
    let resources = resolve_resources(resources_dir)?;
    let value = read_json(&resources.join("release.json"))?;
    Ok(serde_json::from_value(value)?)
}

pub fn install_resource_update(
    resources_dir: Option<PathBuf>,
    zipball_url: &str,
    release: &str,
    repo: &str,
    logger: &dyn LogSink,
) -> Result<()> {
    if !zipball_url.starts_with("https://") {
        return err("更新下载地址必须是 HTTPS。");
    }
    let target_resources = resolve_resources(resources_dir)?;
    let temp_root = env::temp_dir().join(format!("claude-zh-resource-update-{}", Uuid::new_v4()));
    let archive = temp_root.join("release.zip");
    let unpack_dir = temp_root.join("unpacked");
    fs::create_dir_all(&unpack_dir)?;
    logger.info(format!("开始下载补丁资源更新: {zipball_url}"));
    download_release_archive(zipball_url, &archive, logger)?;
    logger.info("补丁资源下载完成，开始解压。");
    extract_release_archive(&archive, &unpack_dir, logger)?;
    let source_resources = find_extracted_resources_dir(&unpack_dir)
        .ok_or_else(|| CoreError::Message("更新包中未找到 resources 目录。".to_string()))?;
    logger.info(format!(
        "开始覆盖随包资源目录: {}",
        target_resources.display()
    ));
    copy_resources_over(&source_resources, &target_resources)?;
    write_json(
        &target_resources.join("release.json"),
        &serde_json::json!({ "repo": repo, "release": release }),
    )?;
    let _ = remove_path(&temp_root);
    logger.info(format!("补丁资源已更新到 {release}。"));
    Ok(())
}

fn copy_resources_over(source: &Path, target: &Path) -> Result<()> {
    for entry in WalkDir::new(source) {
        let entry = entry?;
        let rel = entry.path().strip_prefix(source).unwrap();
        if rel.as_os_str().is_empty() {
            continue;
        }
        let out = target.join(rel);
        if entry.file_type().is_dir() {
            fs::create_dir_all(&out)?;
        } else if entry.file_type().is_file() {
            copy_file(entry.path(), &out)?;
        }
    }
    Ok(())
}

fn find_extracted_resources_dir(root: &Path) -> Option<PathBuf> {
    let direct = root.join("resources");
    if direct.is_dir() {
        return Some(direct);
    }
    fs::read_dir(root).ok()?.flatten().find_map(|entry| {
        let resources = entry.path().join("resources");
        resources.is_dir().then_some(resources)
    })
}

#[cfg(windows)]
fn download_release_archive(url: &str, target: &Path, logger: &dyn LogSink) -> Result<()> {
    run_command(
        {
            let mut cmd = Command::new("powershell.exe");
            let command = format!(
                "Invoke-WebRequest -Uri {} -OutFile {} -UseBasicParsing",
                powershell_single_quote(url),
                powershell_single_quote(&target.display().to_string())
            );
            cmd.args(["-NoProfile", "-NonInteractive", "-Command", &command]);
            cmd
        },
        logger,
        "下载补丁资源更新包",
    )?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn download_release_archive(url: &str, target: &Path, logger: &dyn LogSink) -> Result<()> {
    run_command(
        {
            let mut cmd = Command::new("curl");
            cmd.args(["-L", "--fail", "-o"]);
            cmd.arg(target);
            cmd.arg(url);
            cmd
        },
        logger,
        "下载补丁资源更新包",
    )?;
    Ok(())
}

#[cfg(not(any(target_os = "macos", windows)))]
fn download_release_archive(_url: &str, _target: &Path, _logger: &dyn LogSink) -> Result<()> {
    err("unsupported platform")
}

#[cfg(windows)]
fn extract_release_archive(archive: &Path, target: &Path, logger: &dyn LogSink) -> Result<()> {
    run_command(
        {
            let mut cmd = Command::new("powershell.exe");
            let command = format!(
                "Expand-Archive -Path {} -DestinationPath {} -Force",
                powershell_single_quote(&archive.display().to_string()),
                powershell_single_quote(&target.display().to_string())
            );
            cmd.args(["-NoProfile", "-NonInteractive", "-Command", &command]);
            cmd
        },
        logger,
        "解压补丁资源更新包",
    )?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn extract_release_archive(archive: &Path, target: &Path, logger: &dyn LogSink) -> Result<()> {
    run_command(
        {
            let mut cmd = Command::new("unzip");
            cmd.arg("-q").arg(archive).arg("-d").arg(target);
            cmd
        },
        logger,
        "解压补丁资源更新包",
    )?;
    Ok(())
}

#[cfg(not(any(target_os = "macos", windows)))]
fn extract_release_archive(_archive: &Path, _target: &Path, _logger: &dyn LogSink) -> Result<()> {
    err("unsupported platform")
}

#[cfg(windows)]
fn powershell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}
