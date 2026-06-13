//! Windows 纯净备份管理。
//!
//! 本模块负责备份路径生成、备份创建和备份查找。
//! 备份逻辑集中在本文件（117 行），而恢复逻辑分布在 restore.rs（~694 行）。
//! 比例失衡的根因：备份创建是一次性拷贝操作，逻辑简单；
//! 恢复则涉及文件锁 retry、dry-run 预演、legacy 格式兼容、artifact 清理等，
//! 复杂度天然更高，不适合拆入本模块。

#![cfg(windows)]

use chrono::Local;
use claude_zh_core::{
    copy_file, err, write_json, CoreError, LogSink, LogSinkExt, Result,
};
use std::{
    fs,
    path::{Path, PathBuf},
};

use super::install::copy_dir_recursive;

pub(super) fn windows_external_backup_root() -> Result<PathBuf> {
    let Some(local) = dirs::data_local_dir() else {
        return err("未找到 LocalAppData，无法创建 Windows 包外备份。");
    };
    Ok(local.join("ClaudeDesktopZhCn").join("pristine-backups"))
}

pub(super) fn windows_external_backup_prefix(app: &Path) -> Result<String> {
    app.file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.to_string())
        .ok_or_else(|| CoreError::Message(format!("无法识别安装目录名: {}", app.display())))
}

pub(super) fn windows_latest_pristine_backup(app: &Path) -> Result<Option<PathBuf>> {
    let root = windows_external_backup_root()?;
    let prefix = format!("{}_", windows_external_backup_prefix(app)?);
    let Ok(entries) = fs::read_dir(&root) else {
        return Ok(None);
    };
    let mut backups: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_dir()
                && path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(&prefix))
        })
        .collect();
    backups.sort();
    Ok(backups.pop())
}

pub(super) fn windows_claude_exe_path(app_dir: &Path) -> Result<PathBuf> {
    [app_dir.join("Claude.exe"), app_dir.join("claude.exe")]
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| CoreError::Message(format!("未找到 Claude.exe: {}", app_dir.display())))
}

pub(super) fn write_windows_pristine_backup(
    snapshot_dir: &Path,
    app: &Path,
    resources: &Path,
    logger: &dyn LogSink,
) -> Result<()> {
    let app_dir = resources
        .parent()
        .ok_or_else(|| CoreError::Message("resources 路径无父目录。".to_string()))?;
    fs::create_dir_all(snapshot_dir.join("app"))?;
    copy_file(
        &windows_claude_exe_path(app_dir)?,
        &snapshot_dir.join("app").join("Claude.exe"),
    )?;
    copy_dir_recursive(resources, &snapshot_dir.join("app").join("resources"))?;
    write_json(
        &snapshot_dir.join("metadata.json"),
        &serde_json::json!({
            "capturedAt": Local::now().to_rfc3339(),
            "installLocation": app.display().to_string(),
            "package": windows_external_backup_prefix(app)?,
        }),
    )?;
    logger.info(format!("已写入包外纯净备份: {}", snapshot_dir.display()));
    Ok(())
}

pub(super) fn ensure_windows_pristine_backup(
    app: &Path,
    resources: &Path,
    logger: &dyn LogSink,
) -> Result<PathBuf> {
    if let Some(existing) = windows_latest_pristine_backup(app)? {
        logger.info(format!("使用现有包外纯净备份: {}", existing.display()));
        return Ok(existing);
    }
    if super::install::windows_resources_look_patched(resources) {
        return err("未找到包外纯净备份，且当前 Claude Desktop 已包含补丁痕迹。请先重装官方 Claude Desktop 并确认能启动，再重新安装补丁。");
    }
    let snapshot_dir = windows_external_backup_root()?.join(format!(
        "{}_{}",
        windows_external_backup_prefix(app)?,
        Local::now().format("%Y%m%d-%H%M%S")
    ));
    write_windows_pristine_backup(&snapshot_dir, app, resources, logger)?;
    Ok(snapshot_dir)
}

#[cfg(test)]
mod tests {
    use super::windows_external_backup_prefix;
    use std::path::Path;

    #[test]
    fn windows_external_backup_prefix_uses_package_dir_name() {
        let app = Path::new(r"C:\Program Files\WindowsApps\Claude_1.2.3.4_x64__pzs8sxrjxfjjc");

        let prefix = windows_external_backup_prefix(app).unwrap();

        assert_eq!(prefix, "Claude_1.2.3.4_x64__pzs8sxrjxfjjc");
    }
}
