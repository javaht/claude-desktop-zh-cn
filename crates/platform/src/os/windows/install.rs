#![cfg(windows)]

use chrono::Local;
use claude_zh_core::{
    asar_header_hash, copy_file, err, install_into_resources, patched_version_record,
    set_config_locale, write_json, CoreError, InstallPaths, InstallRequest, LogSink, LogSinkExt,
    Result,
};
use std::{
    env,
    fs,
    path::Path,
};
use walkdir::WalkDir;

use crate::{environment::detect_claude, paths::claude_config_paths};

use super::permissions::{acquire_windowsapps_permission, windowsapps_permission_targets};
use super::backup::ensure_windows_pristine_backup;
use super::restore::{restore_windows_backup_from_snapshot, try_cleanup_windows_restore_artifacts};

/// 使用 Windows API MoveFileExW 实现原子替换文件。
/// 与 POSIX fs::rename 不同，Windows 的 fs::rename 在目标已存在时会失败。
/// MoveFileExW + MOVEFILE_REPLACE_EXISTING 可以真正原子替换。
#[cfg(windows)]
fn atomic_replace_file(src: &Path, dst: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows::core::PCWSTR;
    use windows::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH};

    let src_w: Vec<u16> = src.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    let dst_w: Vec<u16> = dst.as_os_str().encode_wide().chain(std::iter::once(0)).collect();

    unsafe {
        MoveFileExW(
            PCWSTR(src_w.as_ptr()),
            PCWSTR(dst_w.as_ptr()),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
        .map_err(|e| CoreError::Message(format!("MoveFileExW 失败: {e}")))?;
    }
    Ok(())
}

pub(super) fn windows_resources_look_patched(resources: &Path) -> bool {
    resources.join("zh-CN.json").exists()
        || resources.join("zh-CN.lproj").exists()
        || resources.join("zh_CN.lproj").exists()
}

pub(super) fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    if dst.exists() {
        claude_zh_core::remove_path(dst)?;
    }
    fs::create_dir_all(dst)?;
    for entry in WalkDir::new(src) {
        let entry = entry?;
        let rel = entry.path().strip_prefix(src).unwrap();
        let target = dst.join(rel);
        if entry.file_type().is_dir() {
            fs::create_dir_all(&target)?;
        } else if entry.file_type().is_file() {
            copy_file(entry.path(), &target)?;
        }
    }
    Ok(())
}

/// 在 exe 二进制数据中查找并替换 asar 完整性哈希。
/// 返回修改后的数据（如有修改）或错误。
fn patch_exe_hash_data(data: &mut [u8], new_hash: &str) -> Result<()> {
    let marker = br#"resources\\app.asar","alg":"SHA256","value":""#;

    // 查找所有匹配位置
    let positions: Vec<usize> = data
        .windows(marker.len())
        .enumerate()
        .filter(|(_, window)| *window == marker)
        .map(|(i, _)| i)
        .collect();

    if positions.is_empty() {
        return err("未找到 Claude.exe app.asar 完整性标记。");
    }
    if positions.len() > 1 {
        return err(format!(
            "找到 {} 个 app.asar 完整性标记（期望 1 个），拒绝 patch。",
            positions.len()
        ));
    }

    let pos = positions[0];
    let hash_start = pos + marker.len();
    if hash_start + 64 > data.len() {
        return err("Claude.exe app.asar 完整性标记边界无效。");
    }

    // 校验原有 64 字节是合法 hex
    let existing_hash = &data[hash_start..hash_start + 64];
    if !existing_hash.iter().all(|&b| b.is_ascii_hexdigit()) {
        return err("Claude.exe app.asar 完整性标记后 64 字节不是合法十六进制，拒绝 patch。");
    }

    // 校验 new_hash 长度
    let new_hash_bytes = new_hash.as_bytes();
    if new_hash_bytes.len() != 64 {
        return err(format!(
            "新哈希长度为 {}（期望 64），内部错误。",
            new_hash_bytes.len()
        ));
    }

    data[hash_start..hash_start + 64].copy_from_slice(new_hash_bytes);
    Ok(())
}

fn sync_windows_exe_asar_integrity(resources: &Path, logger: &dyn LogSink) -> Result<()> {
    let app = resources
        .parent()
        .ok_or_else(|| CoreError::Message("resources 路径无父目录。".to_string()))?;
    let exe = [app.join("Claude.exe"), app.join("claude.exe")]
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| CoreError::Message("未找到 Claude.exe。".to_string()))?;
    let header_hash = asar_header_hash(&resources.join("app.asar"))?;
    let mut data = fs::read(&exe)?;
    patch_exe_hash_data(&mut data, &header_hash)?;

    // 原子写入：先写临时文件再 rename
    let tmp_path = exe.with_extension("exe.tmp");
    fs::write(&tmp_path, &data)?;
    atomic_replace_file(&tmp_path, &exe)?;

    logger.info("已同步 Claude.exe app.asar 完整性哈希");
    Ok(())
}

fn save_patched_version(
    app: &Path,
    mode: &str,
    language: &str,
    logger: &dyn LogSink,
) -> Result<()> {
    let Some(local) = dirs::data_local_dir() else {
        return Ok(());
    };
    let dir = local.join("ClaudeDesktopZhCn");
    fs::create_dir_all(&dir)?;
    let exe = env::current_exe().ok();
    write_json(
        &dir.join("patched-version.json"),
        &patched_version_record(app, mode, language, exe.as_deref()),
    )?;
    logger.info("已记录补丁版本");
    Ok(())
}

/// 安装失败后尝试回滚到纯净备份。永远返回 Err：
/// - 回滚成功 → 错误消息说明已自动恢复
/// - 回滚失败 → 错误消息包含原始错误和回滚错误，并提示手动恢复路径
fn rollback_after_windows_install_failure(
    original_error: &CoreError,
    pristine_backup: &Path,
    app_dir: &Path,
    target_resources: &Path,
    logger: &dyn LogSink,
) -> CoreError {
    logger.error(format!("安装失败，正在尝试从纯净备份恢复官方文件：{original_error}"));
    match restore_windows_backup_from_snapshot(pristine_backup, app_dir, target_resources, logger) {
        Ok(()) => CoreError::Message(format!(
            "Windows 安装失败，已自动恢复官方文件: {original_error}"
        )),
        Err(rollback_error) => {
            logger.error(format!("自动恢复也失败: {rollback_error}"));
            CoreError::Message(format!(
                "Windows 安装失败: {original_error}；自动恢复也失败: {rollback_error}。请手动从 {} 恢复 {} 和 {}",
                pristine_backup.display(),
                app_dir.display(),
                target_resources.display(),
            ))
        }
    }
}

pub(crate) fn platform_install_patch(
    resources: &Path,
    req: &InstallRequest,
    logger: &dyn LogSink,
) -> Result<()> {
    let (app, target_resources, _) =
        detect_claude().ok_or_else(|| CoreError::Message("未找到 Claude Desktop。".to_string()))?;
    logger.info(format!("检测到 Claude Desktop: {}", app.display()));
    logger.info(format!("目标 resources: {}", target_resources.display()));
    let pristine_backup = ensure_windows_pristine_backup(&app, &target_resources, logger)?;
    if req.dry_run {
        logger.info("dry-run：复制 resources 到临时目录验证，不会修改真实 Claude 安装。");
        let tmp_root = env::temp_dir().join(format!(
            "claude-zh-cn-rs-win-{}",
            Local::now().format("%Y%m%d-%H%M%S")
        ));
        let temp_resources = tmp_root.join("resources");
        logger.info(format!(
            "正在复制 resources 到临时目录: {}",
            temp_resources.display()
        ));
        copy_dir_recursive(&target_resources, &temp_resources)?;
        logger.info("临时 resources 复制完成，开始验证补丁写入。");
        install_into_resources(
            InstallPaths {
                source_resources: resources,
                target_resources: &temp_resources,
                mac_app_root: None,
            },
            &req.language,
            &req.mode,
            None,
            logger,
        )?;
        logger.info(format!(
            "dry-run 完成，临时 resources 保留在: {}",
            temp_resources.display()
        ));
        return Ok(());
    }
    super::quit_claude(logger);
    // WindowsApps 目录由 TrustedInstaller 拥有，管理员默认无写入权限
    for path in windowsapps_permission_targets(&target_resources) {
        acquire_windowsapps_permission(&path, logger)?;
    }
    let install_result = (|| -> Result<()> {
        let app_dir = target_resources
            .parent()
            .ok_or_else(|| CoreError::Message("resources 路径无父目录。".to_string()))?;
        try_cleanup_windows_restore_artifacts(app_dir, logger);
        install_into_resources(
            InstallPaths {
                source_resources: resources,
                target_resources: &target_resources,
                mac_app_root: None,
            },
            &req.language,
            &req.mode,
            None,
            logger,
        )?;
        logger.info("Windows resources 补丁写入完成。");
        logger.info("开始同步 Windows Claude.exe app.asar 完整性标记。");
        sync_windows_exe_asar_integrity(&target_resources, logger)?;
        logger.info("开始写入 Claude 语言配置。");
        for config in claude_config_paths() {
            set_config_locale(&config, &req.language, logger)?;
        }
        save_patched_version(&app, &req.mode, &req.language, logger)?;
        let _ = super::unregister_update_watcher(logger);
        if req.launch_after {
            super::launch_claude(&app, logger);
        }
        Ok(())
    })();
    if let Err(error) = install_result {
        let app_dir = target_resources
            .parent()
            .ok_or_else(|| CoreError::Message("resources 路径无父目录。".to_string()))?;
        let rollback_err = rollback_after_windows_install_failure(
            &error,
            &pristine_backup,
            app_dir,
            &target_resources,
            logger,
        );
        for config in claude_config_paths() {
            if let Err(e) = set_config_locale(&config, "en-US", logger) {
                logger.warn(format!("恢复 locale 失败: {} — {e}", config.display()));
            }
        }
        return Err(rollback_err);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{patch_exe_hash_data, rollback_after_windows_install_failure, windows_resources_look_patched};
    use claude_zh_core::{now_millis, CoreError, NoopLogger};
    use std::fs;

    #[test]
    fn windows_resources_look_patched_detects_added_language_files() {
        let root = std::env::temp_dir().join(format!(
            "claude-zh-platform-patched-detect-{}",
            now_millis()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("zh-CN.json"), "{}").unwrap();

        assert!(windows_resources_look_patched(&root));

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn patch_exe_hash_data_rejects_zero_markers() {
        let mut data = b"no marker here".to_vec();
        assert!(patch_exe_hash_data(&mut data, &"a".repeat(64)).is_err());
    }

    #[test]
    fn patch_exe_hash_data_rejects_multiple_markers() {
        let marker = br#"resources\\app.asar","alg":"SHA256","value":""#;
        let mut data = Vec::new();
        data.extend_from_slice(marker);
        data.extend_from_slice(b"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        data.extend_from_slice(marker);
        data.extend_from_slice(b"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        assert!(patch_exe_hash_data(&mut data, &"a".repeat(64)).is_err());
    }

    #[test]
    fn patch_exe_hash_data_rejects_non_hex_existing() {
        let marker = br#"resources\\app.asar","alg":"SHA256","value":""#;
        let mut data = Vec::new();
        data.extend_from_slice(marker);
        data.extend_from_slice(b"GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG"); // 非 hex
        assert!(patch_exe_hash_data(&mut data, &"a".repeat(64)).is_err());
    }

    #[test]
    fn patch_exe_hash_data_replaces_single_marker() {
        let marker = br#"resources\\app.asar","alg":"SHA256","value":""#;
        let mut data = Vec::new();
        data.extend_from_slice(marker);
        data.extend_from_slice(b"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        let new_hash = "a".repeat(64);
        patch_exe_hash_data(&mut data, &new_hash).unwrap();
        assert_eq!(&data[marker.len()..marker.len() + 64], new_hash.as_bytes());
    }

    #[test]
    fn rollback_after_windows_install_failure_rollback_ok_reports_auto_recovery() {
        let root = std::env::temp_dir().join(format!(
            "claude-zh-platform-rollback-ok-{}",
            now_millis()
        ));
        let _ = fs::remove_dir_all(&root);
        let app_dir = root.join("app");
        let resources = app_dir.join("resources");
        let snapshot = root.join("snapshot");
        // 建立回滚所需的纯净备份结构
        fs::create_dir_all(snapshot.join("app").join("resources")).unwrap();
        fs::write(snapshot.join("app").join("Claude.exe"), b"clean-exe").unwrap();
        fs::write(
            snapshot.join("app").join("resources").join("app.asar"),
            b"clean-asar",
        )
        .unwrap();
        // 建立当前（被破坏的）安装结构
        fs::create_dir_all(&resources).unwrap();
        fs::write(app_dir.join("Claude.exe"), b"patched-exe").unwrap();
        fs::write(resources.join("app.asar"), b"patched-asar").unwrap();

        let original = CoreError::Message("模拟安装失败".to_string());
        let result = rollback_after_windows_install_failure(
            &original,
            &snapshot,
            &app_dir,
            &resources,
            &NoopLogger,
        );

        // 永远返回 Err
        let msg = result.to_string();
        assert!(msg.contains("已自动恢复官方文件"), "消息应说明已自动恢复: {msg}");
        assert!(msg.contains("模拟安装失败"), "消息应包含原始错误: {msg}");

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn rollback_after_windows_install_failure_rollback_fail_reports_manual_recovery() {
        let root = std::env::temp_dir().join(format!(
            "claude-zh-platform-rollback-fail-{}",
            now_millis()
        ));
        let _ = fs::remove_dir_all(&root);
        let app_dir = root.join("app");
        let resources = app_dir.join("resources");
        // 不创建 snapshot 目录，使 restore 必然失败
        let nonexistent_snapshot = root.join("no-snapshot-here");
        fs::create_dir_all(&resources).unwrap();
        fs::write(app_dir.join("Claude.exe"), b"patched-exe").unwrap();

        let original = CoreError::Message("模拟安装失败".to_string());
        let result = rollback_after_windows_install_failure(
            &original,
            &nonexistent_snapshot,
            &app_dir,
            &resources,
            &NoopLogger,
        );

        // 永远返回 Err
        let msg = result.to_string();
        assert!(msg.contains("自动恢复也失败"), "消息应说明恢复失败: {msg}");
        assert!(
            msg.contains(&nonexistent_snapshot.display().to_string()),
            "消息应包含 pristine_backup 路径: {msg}"
        );
        assert!(
            msg.contains(&app_dir.display().to_string()),
            "消息应包含 app_dir 路径: {msg}"
        );
        assert!(
            msg.contains(&resources.display().to_string()),
            "消息应包含 target_resources 路径: {msg}"
        );
        assert!(msg.contains("模拟安装失败"), "消息应包含原始错误: {msg}");

        let _ = fs::remove_dir_all(&root);
    }
}
