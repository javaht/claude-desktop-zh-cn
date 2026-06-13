#![cfg(windows)]

use std::path::{Path, PathBuf};

use crate::logging::{hide_command_window, run_command};
use claude_zh_core::{LogSink, LogSinkExt, Result};

/// 剥离 Windows canonicalize 产生的 `\\?\` UNC 长路径前缀。
///
/// `Path::canonicalize` 在 Windows 上返回带 `\\?\` 前缀的扩展长度路径，
/// 但 `takeown.exe` / `icacls.exe` 等内置命令不识别该前缀，传入会报
/// "File or Directory not found"。本函数在传给外部命令前还原为普通路径。
fn strip_unc_prefix(path: PathBuf) -> PathBuf {
    let s = path.to_string_lossy();
    if let Some(rest) = s.strip_prefix(r"\\?\") {
        // UNC server 形式 \\?\UNC\server\share -> \\server\share，保守起见不动
        if rest.starts_with("UNC\\") {
            return path;
        }
        return PathBuf::from(rest.to_string());
    }
    path
}

pub(super) fn windowsapps_permission_targets(resources: &Path) -> Vec<PathBuf> {
    // canonicalize 用于安全比较：处理大小写、短路径、符号链接等
    let resources_canon = match resources.canonicalize() {
        Ok(canon) => canon,
        Err(_) => return Vec::new(), // 路径不存在，不需要权限
    };
    let windows_apps_canon = match PathBuf::from(r"C:\Program Files\WindowsApps").canonicalize() {
        Ok(canon) => canon,
        Err(_) => return Vec::new(),
    };
    if !resources_canon.starts_with(&windows_apps_canon) {
        return Vec::new();
    }
    // 输出剥离 \\?\ 前缀的路径，避免 takeown/icacls 不识别 UNC 长路径
    let resources_clean = strip_unc_prefix(resources_canon.clone());
    let mut targets = vec![resources_clean.clone()];
    if let Some(app_dir) = resources_clean.parent() {
        targets.push(app_dir.to_path_buf());
    }
    targets
}

pub(super) fn acquire_windowsapps_permission(path: &Path, logger: &dyn LogSink) -> Result<()> {
    let path_str = path.display().to_string();
    logger.info("正在获取 WindowsApps 目录写入权限。");
    // takeown: 获取目录所有权
    let mut takeown = std::process::Command::new("takeown");
    hide_command_window(&mut takeown);
    takeown.args(["/F", &path_str, "/R", "/A", "/D", "Y"]);
    run_command(takeown, logger, "获取目录所有权")?;
    // icacls: 授予管理员完全控制
    let mut icacls = std::process::Command::new("icacls");
    hide_command_window(&mut icacls);
    icacls.args([&path_str, "/grant", "Administrators:(OI)(CI)F", "/T", "/C"]);
    run_command(icacls, logger, "授予管理员写入权限")?;
    logger.info("WindowsApps 目录权限已更新。");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::strip_unc_prefix;
    use std::path::PathBuf;

    #[test]
    fn strip_unc_prefix_removes_extended_length_marker() {
        let p = PathBuf::from(r"\\?\C:\Program Files\WindowsApps\Claude_xxx\app");
        assert_eq!(strip_unc_prefix(p), PathBuf::from(r"C:\Program Files\WindowsApps\Claude_xxx\app"));
    }

    #[test]
    fn strip_unc_prefix_leaves_unc_server_paths() {
        let p = PathBuf::from(r"\\?\UNC\server\share\file");
        assert_eq!(strip_unc_prefix(p.clone()), p);
    }

    #[test]
    fn strip_unc_prefix_leaves_normal_paths() {
        let p = PathBuf::from(r"C:\Program Files\WindowsApps");
        assert_eq!(strip_unc_prefix(p.clone()), p);
    }
}

