use claude_zh_core::{
    copy_file, err, read_json, remove_path, write_json, CoreError, LogSink, LogSinkExt, Result,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};
use uuid::Uuid;
use walkdir::WalkDir;

use crate::logging::run_command;

const ALLOWED_HOSTS: &[&str] = &[
    "github.com",
    "codeload.github.com",
    "objects.githubusercontent.com",
    "api.github.com",
];

fn validate_resource_url(zipball_url: &str, expected_repo: &str) -> Result<()> {
    if !zipball_url.starts_with("https://") {
        return err("更新下载地址必须是 HTTPS。");
    }
    let after_scheme = &zipball_url["https://".len()..];
    let (host, path) = match after_scheme.find('/') {
        Some(i) => (&after_scheme[..i], &after_scheme[i..]),
        None => (after_scheme, ""),
    };
    // 拒绝 host 中含有 userinfo (@) 或端口 (:)
    if host.contains('@') || host.contains(':') {
        return err(format!("URL host 含禁止字符: {zipball_url}"));
    }
    if !ALLOWED_HOSTS.contains(&host) {
        return err(format!(
            "URL host 不在白名单 ({}): {zipball_url}",
            ALLOWED_HOSTS.join(", ")
        ));
    }
    // path-aware repo 校验：github.com / codeload.github.com / api.github.com
    let repo_check_required = matches!(
        host,
        "github.com" | "codeload.github.com" | "api.github.com"
    );
    if repo_check_required && !expected_repo.is_empty() {
        let parts: Vec<&str> = expected_repo.splitn(2, '/').collect();
        if parts.len() != 2 || parts[0].is_empty() || parts[1].is_empty() {
            return err(format!("expected_repo 格式不合法: {expected_repo}"));
        }
        let (owner, repo) = (parts[0], parts[1]);
        let trimmed = path.trim_start_matches('/');
        let segs: Vec<&str> = trimmed.split('/').collect();
        let ok = if host == "api.github.com" {
            // api.github.com 必须以 repos/{owner}/{repo} 开头
            segs.len() >= 3 && segs[0] == "repos" && segs[1] == owner && segs[2] == repo
        } else {
            // github.com / codeload.github.com 必须以 {owner}/{repo} 开头
            segs.len() >= 2 && segs[0] == owner && segs[1] == repo
        };
        if !ok {
            return err(format!(
                "URL path 不属于期望的 {expected_repo} 仓库: {zipball_url}"
            ));
        }
    }
    Ok(())
}

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
    logger: &dyn LogSink,
) -> Result<()> {
    let target_resources = resolve_resources(resources_dir)?;
    // 从 manifest 读取 repo，不再信任前端传入
    let manifest = resource_release_manifest(Some(target_resources.clone()))?;
    let repo = manifest.repo;

    validate_resource_url(zipball_url, &repo)?;

    let temp_root = env::temp_dir().join(format!("claude-zh-resource-update-{}", Uuid::new_v4()));
    let archive = temp_root.join("release.zip");
    let unpack_dir = temp_root.join("unpacked");
    fs::create_dir_all(&unpack_dir)?;
    ensure_resources_writable(&target_resources)?;
    logger.info(format!("开始下载补丁资源更新: {zipball_url}"));
    download_release_archive(zipball_url, &archive, logger)?;
    logger.info("补丁资源下载完成，开始解压。");
    extract_release_archive(&archive, &unpack_dir, logger)?;

    // S2: zip 解压基本校验
    let source_resources = find_extracted_resources_dir(&unpack_dir)
        .ok_or_else(|| CoreError::Message("更新包中未找到 resources 目录。".to_string()))?;

    let file_count = WalkDir::new(&source_resources)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .count();
    if file_count == 0 {
        let _ = remove_path(&temp_root);
        return err("更新包 resources 目录为空，拒绝安装。");
    }
    let marker_file = source_resources.join("frontend-zh-CN.json");
    if !marker_file.is_file() {
        let _ = remove_path(&temp_root);
        return err("更新包缺少关键文件 frontend-zh-CN.json，拒绝安装。");
    }
    if file_count > 500 {
        let _ = remove_path(&temp_root);
        return err(format!("更新包文件数异常（{file_count} > 500），拒绝安装。"));
    }

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

fn ensure_resources_writable(target: &Path) -> Result<()> {
    let probe = target.join(format!(".zh-cn-writable-probe-{}", Uuid::new_v4()));
    fs::write(&probe, [0u8]).map_err(|e| {
        err::<()>(format!(
            "随包资源目录不可写：{}。请使用最新安装器升级整个应用，或以管理员身份重新启动后再试。底层错误：{e}",
            target.display()
        ))
        .unwrap_err()
    })?;
    let _ = fs::remove_file(&probe);
    Ok(())
}

fn copy_resources_over(source: &Path, target: &Path) -> Result<()> {
    // 收集 source 中所有文件的相对路径
    let mut source_files = HashSet::new();
    for entry in WalkDir::new(source) {
        let entry = entry?;
        if !entry.file_type().is_file() {
            continue;
        }
        let rel = entry.path().strip_prefix(source).unwrap();
        source_files.insert(rel.to_path_buf());
    }
    // 删除 target 中不在 source 集合中的 stale 文件
    if target.is_dir() {
        for entry in WalkDir::new(target) {
            let entry = entry?;
            if !entry.file_type().is_file() {
                continue;
            }
            let rel = match entry.path().strip_prefix(target) {
                Ok(r) => r,
                Err(_) => continue,
            };
            if !source_files.contains(rel) {
                // stale 文件删除失败不阻塞主流程（可能被进程占用或权限问题）
                let _ = remove_path(entry.path());
            }
        }
    }
    // 从 source 复制到 target
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

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_REPO: &str = "owner/repo";

    #[test]
    fn validate_resource_url_accepts_github_releases() {
        assert!(validate_resource_url(
            "https://github.com/owner/repo/releases/download/v1.0/file.zip",
            TEST_REPO
        )
        .is_ok());
    }

    #[test]
    fn validate_resource_url_accepts_codeload() {
        assert!(validate_resource_url(
            "https://codeload.github.com/owner/repo/zip/refs/tags/v1.0",
            TEST_REPO
        )
        .is_ok());
    }

    #[test]
    fn validate_resource_url_accepts_objects() {
        // objects 域名的 URL 不一定包含 repo 路径，用空字符串跳过 repo 校验
        assert!(validate_resource_url(
            "https://objects.githubusercontent.com/path/to/file",
            ""
        )
        .is_ok());
    }

    #[test]
    fn validate_resource_url_accepts_api() {
        assert!(validate_resource_url(
            "https://api.github.com/repos/owner/repo/releases",
            TEST_REPO
        )
        .is_ok());
    }

    #[test]
    fn validate_resource_url_rejects_http() {
        assert!(validate_resource_url("http://github.com/owner/repo", TEST_REPO).is_err());
    }

    #[test]
    fn validate_resource_url_rejects_other_host() {
        assert!(validate_resource_url("https://evil.com/owner/repo/payload.zip", TEST_REPO).is_err());
        assert!(validate_resource_url("https://github.com.evil.com/owner/repo/x", TEST_REPO).is_err());
    }

    #[test]
    fn validate_resource_url_rejects_malformed() {
        assert!(validate_resource_url("not a url", TEST_REPO).is_err());
        assert!(validate_resource_url("", TEST_REPO).is_err());
    }

    #[test]
    fn validate_resource_url_rejects_wrong_repo_on_github() {
        // 同一 host 但 repo 不匹配
        assert!(validate_resource_url(
            "https://github.com/evilowner/evilrepo/releases/download/v1/file.zip",
            TEST_REPO
        )
        .is_err());
    }

    #[test]
    fn validate_resource_url_rejects_wrong_repo_on_codeload() {
        assert!(validate_resource_url(
            "https://codeload.github.com/evil/evil/zip/refs/heads/main",
            TEST_REPO
        )
        .is_err());
    }

    #[test]
    fn validate_resource_url_rejects_wrong_repo_on_api() {
        assert!(validate_resource_url(
            "https://api.github.com/repos/evil/evil/releases/latest",
            TEST_REPO
        )
        .is_err());
    }

    #[test]
    fn validate_resource_url_accepts_objects_without_repo_check() {
        // objects.githubusercontent.com 的 path 是不透明的，跳过 repo 校验
        assert!(validate_resource_url(
            "https://objects.githubusercontent.com/some/opaque/token",
            TEST_REPO
        )
        .is_ok());
    }
}
