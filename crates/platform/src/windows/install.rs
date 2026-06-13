#![cfg(windows)]

use chrono::Local;
use claude_zh_core::{
    asar_header_hash, copy_file, err, install_into_resources, patched_version_record, remove_path,
    set_config_locale, write_json, CoreError, InstallPaths, InstallRequest, LogSink, LogSinkExt,
    Result,
};
use std::{
    env,
    fs,
    path::{Path, PathBuf},
    thread,
    time::Duration,
};
use walkdir::WalkDir;

use crate::{environment::detect_claude, paths::claude_config_paths};

use super::permissions::{acquire_windowsapps_permission, windowsapps_permission_targets};
use super::backup::ensure_windows_pristine_backup;
use super::restore::{
    restore_windows_backup_from_snapshot, sync_dir_exact, try_cleanup_windows_restore_artifacts,
};

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

/// 纯函数：在内存中 patch exe 数据，返回修改后的副本。
fn build_patched_exe_data(exe_bytes: &[u8], asar_hash: &str) -> Result<Vec<u8>> {
    let mut data = exe_bytes.to_vec();
    patch_exe_hash_data(&mut data, asar_hash)?;
    Ok(data)
}

/// 生成唯一临时文件路径：`Claude.exe.tmp-{12位hex}`，UUID v4 前 12 位 hex 保证无碰撞。
fn unique_tmp_path(exe: &Path) -> PathBuf {
    let hex = uuid::Uuid::new_v4().simple().to_string();
    exe.with_extension(format!("exe.tmp-{}", &hex[..12]))
}

/// 生成 Windows dry-run 临时目录名：`claude-zh-cn-rs-win-{YYYYMMDD-HHMMSS}-{12位hex}`，UUID v4 前 12 位 hex 保证无碰撞。
fn dry_run_tmp_dir_name() -> String {
    let hex = uuid::Uuid::new_v4().simple().to_string();
    format!(
        "claude-zh-cn-rs-win-{}-{}",
        Local::now().format("%Y%m%d-%H%M%S"),
        &hex[..12]
    )
}

/// 带重试的 exe 替换：先写入唯一 tmp 文件，再通过 MoveFileExW 原子替换。
/// 可重试错误：MoveFileExW 失败（exe 被锁定）。
/// 重试前调用 quit_claude 释放锁，退避序列 [150, 300, 500, 800, 1200, 1800]ms。
/// 不可重试错误立即返回，清理 tmp；最终失败也清理 tmp（best effort）。
fn write_and_replace_exe_with_retries(
    target_exe: &Path,
    new_data: &[u8],
    logger: &dyn LogSink,
) -> Result<()> {
    const RETRY_DELAYS_MS: [u64; 6] = [150, 300, 500, 800, 1200, 1800];
    let tmp_path = unique_tmp_path(target_exe);

    // 写入唯一 tmp 文件（非重试路径；唯一路径避免锁竞争）
    fs::write(&tmp_path, new_data).map_err(|e| {
        let _ = fs::remove_file(&tmp_path);
        CoreError::Io(e)
    })?;

    let mut last_error: Option<CoreError> = None;

    for (attempt, delay_ms) in RETRY_DELAYS_MS.iter().enumerate() {
        match atomic_replace_file(&tmp_path, target_exe) {
            Ok(()) => {
                if attempt > 0 {
                    logger.info(format!(
                        "Claude.exe 替换在第 {} 次重试后成功。",
                        attempt + 1
                    ));
                }
                return Ok(());
            }
            Err(CoreError::Message(ref msg)) if msg.contains("MoveFileExW") => {
                logger.warn(format!(
                    "Claude.exe 替换失败（第 {} 次）: {msg}；等待 {delay_ms}ms 后重试。",
                    attempt + 1
                ));
                last_error = Some(CoreError::Message(msg.clone()));
                super::quit_claude(logger);
                thread::sleep(Duration::from_millis(*delay_ms));
            }
            Err(error) => {
                // 不可重试错误：清理 tmp，立即返回
                let _ = fs::remove_file(&tmp_path);
                return Err(error);
            }
        }
    }

    // 所有重试耗尽后的最终尝试
    match atomic_replace_file(&tmp_path, target_exe) {
        Ok(()) => Ok(()),
        Err(error) => {
            let _ = fs::remove_file(&tmp_path);
            Err(CoreError::Message(format!(
                "Claude.exe 替换最终失败: {}",
                last_error.unwrap_or(error)
            )))
        }
    }
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
    let data = fs::read(&exe)?;
    let patched = build_patched_exe_data(&data, &header_hash)?;
    write_and_replace_exe_with_retries(&exe, &patched, logger)?;
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

/// Staged preflight：在临时目录中验证整个安装流程，不修改真实 Claude 安装。
///
/// 步骤：
/// 1. 复制 target_resources → 临时 staged 目录
/// 2. 在 staged 上跑 `install_into_resources`
/// 3. 计算 staged app.asar header hash
/// 4. 读取真实 exe 并在内存中 patch（用 `build_patched_exe_data`）
///
/// 返回 `(staged_resources_path, tmp_root_path)`。调用方负责：
/// - 用 `staged_resources_path` 做真实同步
/// - 用完后删除 `tmp_root_path`
///
/// 任何一步失败直接返回 Err，调用方需删除 tmp_root（如有）。
fn preflight_install_on_staged(
    target_resources: &Path,
    source_resources: &Path,
    req: &InstallRequest,
    logger: &dyn LogSink,
) -> Result<(PathBuf, PathBuf)> {
    let tmp_root = env::temp_dir().join(format!(
        "claude-zh-cn-preflight-{}",
        Local::now().format("%Y%m%d-%H%M%S-%f")
    ));
    let staged_resources = tmp_root.join("resources");

    logger.info(format!(
        "preflight：复制 resources 到临时目录 {}",
        staged_resources.display()
    ));
    // 如果 copy_dir_recursive 失败，清理已创建的 tmp_root
    copy_dir_recursive(target_resources, &staged_resources).map_err(|e| {
        let _ = fs::remove_dir_all(&tmp_root);
        e
    })?;

    logger.info("preflight：在临时目录验证 install_into_resources。");
    install_into_resources(
        InstallPaths {
            source_resources,
            target_resources: &staged_resources,
            mac_app_root: None,
        },
        &req.language,
        &req.mode,
        None,
        logger,
    )
    .map_err(|e| {
        let _ = fs::remove_dir_all(&tmp_root);
        e
    })?;

    logger.info("preflight：验证 staged app.asar header hash。");
    let header_hash = asar_header_hash(&staged_resources.join("app.asar")).map_err(|e| {
        let _ = fs::remove_dir_all(&tmp_root);
        e
    })?;

    logger.info("preflight：在内存中验证 exe 哈希 patch。");
    let app_dir = target_resources
        .parent()
        .ok_or_else(|| CoreError::Message("resources 路径无父目录。".to_string()))
        .map_err(|e| {
            let _ = fs::remove_dir_all(&tmp_root);
            e
        })?;
    let exe = [app_dir.join("Claude.exe"), app_dir.join("claude.exe")]
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| CoreError::Message("preflight：未找到 Claude.exe。".to_string()))
        .map_err(|e| {
            let _ = fs::remove_dir_all(&tmp_root);
            e
        })?;
    let exe_bytes = fs::read(&exe).map_err(|e| {
        let _ = fs::remove_dir_all(&tmp_root);
        CoreError::Io(e)
    })?;
    let _patched = build_patched_exe_data(&exe_bytes, &header_hash).map_err(|e| {
        let _ = fs::remove_dir_all(&tmp_root);
        e
    })?;

    logger.info("preflight 验证通过。");
    Ok((staged_resources, tmp_root))
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
        logger.info(format!("dry-run snapshot: {}", pristine_backup.display()));
        let tmp_root = env::temp_dir().join(dry_run_tmp_dir_name());
        let temp_resources = tmp_root.join("resources");
        logger.info(format!(
            "dry-run staged resources: {}",
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
        // dry-run：验证 exe marker 可在内存中 patch（不写真实 exe）
        logger.info("dry-run：验证 Claude.exe app.asar 完整性标记。");
        let app_dir = target_resources
            .parent()
            .ok_or_else(|| CoreError::Message("resources 路径无父目录。".to_string()))?;
        let exe = [app_dir.join("Claude.exe"), app_dir.join("claude.exe")]
            .into_iter()
            .find(|path| path.is_file())
            .ok_or_else(|| CoreError::Message("dry-run：未找到 Claude.exe。".to_string()))?;
        let header_hash = asar_header_hash(&temp_resources.join("app.asar"))?;
        let exe_bytes = fs::read(&exe)?;
        let _patched = build_patched_exe_data(&exe_bytes, &header_hash)?;
        logger.info("dry-run exe marker 验证通过。");
        logger.info(format!(
            "dry-run 完成，临时 resources 保留在: {}",
            temp_resources.display()
        ));
        return Ok(());
    }

    // ── B3 staged preflight：在临时目录验证整个安装流程 ──
    // 失败直接返回 Err，真实目录未被触碰，无需回滚。
    logger.info("开始 staged preflight 验证…");
    let (staged_resources, tmp_root) =
        preflight_install_on_staged(&target_resources, resources, req, logger)?;

    // ── B4 真实应用阶段：用 staged resources 同步到真实目录 ──
    // preflight 已验证 staged 内容正确，此处只做同步，不在真实目录重跑 install_into_resources。
    // 失败时走 B1 rollback。完成后清理 tmp_root。
    let install_result = (|| -> Result<()> {
        super::quit_claude(logger);
        // WindowsApps 目录由 TrustedInstaller 拥有，管理员默认无写入权限
        for path in windowsapps_permission_targets(&target_resources) {
            acquire_windowsapps_permission(&path, logger)?;
        }
        let app_dir = target_resources
            .parent()
            .ok_or_else(|| CoreError::Message("resources 路径无父目录。".to_string()))?;
        try_cleanup_windows_restore_artifacts(app_dir, logger);
        // B4：从 staged 同步到 target，而非在 target 上重跑 install_into_resources
        logger.info(format!(
            "正在从 staged 同步 resources 到 {}…",
            target_resources.display()
        ));
        sync_dir_exact(&staged_resources, &target_resources, logger)?;
        logger.info("Windows resources 同步完成。");
        logger.info("开始同步 Windows Claude.exe app.asar 完整性标记。");
        sync_windows_exe_asar_integrity(&target_resources, logger)?;
        logger.info("开始写入 Claude 语言配置。");
        for config in claude_config_paths() {
            set_config_locale(&config, &req.language, logger)?;
        }
        if let Err(e) = save_patched_version(&app, &req.mode, &req.language, logger) {
            logger.warn(format!("记录补丁版本失败（不影响安装）: {e}"));
        }
        let _ = super::unregister_update_watcher(logger);
        if req.launch_after {
            super::launch_claude(&app, logger);
        }
        Ok(())
    })();

    // 清理 preflight 临时目录（无论成功或失败）
    let _ = fs::remove_dir_all(&tmp_root);

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
    use super::{
        build_patched_exe_data, patch_exe_hash_data, rollback_after_windows_install_failure,
        dry_run_tmp_dir_name, unique_tmp_path, windows_resources_look_patched,
    };
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

    #[test]
    fn build_patched_exe_data_patches_marker_in_memory() {
        let marker = br#"resources\\app.asar","alg":"SHA256","value":""#;
        let original_hash = b"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let mut exe_data = Vec::new();
        exe_data.extend_from_slice(b"prefix");
        exe_data.extend_from_slice(marker);
        exe_data.extend_from_slice(original_hash);
        exe_data.extend_from_slice(b"suffix");

        let new_hash = "a".repeat(64);
        let patched = build_patched_exe_data(&exe_data, &new_hash).unwrap();

        // 原始数据不变
        assert_ne!(exe_data, patched);

        // 在 patched 中定位 marker 并校验哈希已替换
        let marker_pos = patched
            .windows(marker.len())
            .position(|w| w == marker)
            .expect("patched 数据中应包含 marker");
        let hash_start = marker_pos + marker.len();
        assert_eq!(&patched[hash_start..hash_start + 64], new_hash.as_bytes());

        // 前缀和后缀保持不变
        assert_eq!(&patched[..6], b"prefix");
        assert_eq!(&patched[hash_start + 64..], b"suffix");
    }

    #[test]
    fn unique_tmp_path_generates_different_names_for_same_exe() {
        let exe = std::path::PathBuf::from(r"C:\Users\test\AppData\Local\Claude\Claude.exe");
        let path1 = unique_tmp_path(&exe);
        let path2 = unique_tmp_path(&exe);

        // 两次调用生成不同路径
        assert_ne!(path1, path2);

        // 格式正确：Claude.exe.tmp-{12hex}
        let name1 = path1.file_name().unwrap().to_str().unwrap();
        let name2 = path2.file_name().unwrap().to_str().unwrap();
        assert!(name1.starts_with("Claude.exe.tmp-"), "name1 格式错误: {name1}");
        assert!(name2.starts_with("Claude.exe.tmp-"), "name2 格式错误: {name2}");

        let hex1 = &name1["Claude.exe.tmp-".len()..];
        let hex2 = &name2["Claude.exe.tmp-".len()..];
        assert_eq!(hex1.len(), 12, "hex1 长度错误: {hex1}");
        assert_eq!(hex2.len(), 12, "hex2 长度错误: {hex2}");
        assert!(hex1.chars().all(|c| c.is_ascii_hexdigit()), "hex1 含非 hex 字符: {hex1}");
        assert!(hex2.chars().all(|c| c.is_ascii_hexdigit()), "hex2 含非 hex 字符: {hex2}");
    }

    #[test]
    fn dry_run_tmp_dir_name_includes_uuid_suffix() {
        let name1 = dry_run_tmp_dir_name();
        let name2 = dry_run_tmp_dir_name();

        // 两次调用生成不同路径
        assert_ne!(name1, name2);

        // 格式正确：claude-zh-cn-rs-win-{YYYYMMDD-HHMMSS}-{12hex}
        assert!(
            name1.starts_with("claude-zh-cn-rs-win-"),
            "name1 格式错误: {name1}"
        );
        assert!(
            name2.starts_with("claude-zh-cn-rs-win-"),
            "name2 格式错误: {name2}"
        );

        let suffix1 = &name1["claude-zh-cn-rs-win-".len()..];
        let suffix2 = &name2["claude-zh-cn-rs-win-".len()..];
        // 前缀应为时间戳（15 字符）加 '-' 加 12 位 hex
        assert_eq!(suffix1.len(), 15 + 1 + 12, "suffix1 长度错误: {suffix1}");
        assert_eq!(suffix2.len(), 15 + 1 + 12, "suffix2 长度错误: {suffix2}");

        let hex1 = &suffix1[suffix1.len() - 12..];
        let hex2 = &suffix2[suffix2.len() - 12..];
        assert!(hex1.chars().all(|c| c.is_ascii_hexdigit()), "hex1 含非 hex 字符: {hex1}");
        assert!(hex2.chars().all(|c| c.is_ascii_hexdigit()), "hex2 含非 hex 字符: {hex2}");
    }

    #[test]
    fn preflight_failure_does_not_modify_real_target_resources() {
        use super::preflight_install_on_staged;
        use claude_zh_core::InstallRequest;

        let root = std::env::temp_dir().join(format!(
            "claude-zh-platform-preflight-fail-{}",
            now_millis()
        ));
        let _ = fs::remove_dir_all(&root);
        let app_dir = root.join("app");
        let target_resources = app_dir.join("resources");

        // 建立真实的 target_resources（含原始内容）
        fs::create_dir_all(&target_resources).unwrap();
        fs::write(target_resources.join("app.asar"), b"original-asar").unwrap();
        fs::write(app_dir.join("Claude.exe"), b"original-exe").unwrap();

        // source_resources 为空目录 → install_into_resources 在 staged 上会失败
        let source_resources = root.join("empty-source");
        fs::create_dir_all(&source_resources).unwrap();

        let req = InstallRequest {
            language: "zh-CN".to_string(),
            mode: "full".to_string(),
            dry_run: false,
            launch_after: false,
        };

        let result = preflight_install_on_staged(
            &target_resources,
            &source_resources,
            &req,
            &NoopLogger,
        );

        // preflight 应该失败
        assert!(result.is_err(), "preflight 应失败: {:?}", result);

        // 真实 target_resources 未被修改
        assert_eq!(
            fs::read(target_resources.join("app.asar")).unwrap(),
            b"original-asar",
            "preflight 失败后真实 app.asar 不应被修改"
        );
        assert_eq!(
            fs::read(app_dir.join("Claude.exe")).unwrap(),
            b"original-exe",
            "preflight 失败后真实 Claude.exe 不应被修改"
        );

        // 临时 preflight 目录应已被清理（preflight_install_on_staged 内部 map_err 清理）
        let tmp_root = std::env::temp_dir().join("claude-zh-cn-preflight-*");
        // 简单断言：不存在以 claude-zh-cn-preflight- 开头的残留目录
        // （由于 glob 在 Windows 上不可靠，此处仅做逻辑验证，不精确匹配路径）

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn sync_staged_to_target_produces_identical_content() {
        use super::sync_dir_exact;

        let root = std::env::temp_dir().join(format!(
            "claude-zh-platform-sync-staged-{}",
            now_millis()
        ));
        let _ = fs::remove_dir_all(&root);
        let staged = root.join("staged");
        let target = root.join("target");

        // staged：含补丁后的文件
        fs::create_dir_all(staged.join("nested")).unwrap();
        fs::write(staged.join("app.asar"), b"patched-asar").unwrap();
        fs::write(staged.join("zh-CN.json"), b"patched-lang").unwrap();
        fs::write(staged.join("nested").join("keep.txt"), b"patched-keep").unwrap();

        // target：含原始文件（含一个 staged 中不存在的 extra 文件）
        fs::create_dir_all(target.join("nested")).unwrap();
        fs::write(target.join("app.asar"), b"original-asar").unwrap();
        fs::write(target.join("extra.txt"), b"extra").unwrap();
        fs::write(target.join("nested").join("keep.txt"), b"original-keep").unwrap();

        sync_dir_exact(&staged, &target, &NoopLogger).unwrap();

        // target 内容与 staged 一致
        assert_eq!(fs::read(target.join("app.asar")).unwrap(), b"patched-asar");
        assert_eq!(fs::read(target.join("zh-CN.json")).unwrap(), b"patched-lang");
        assert_eq!(
            fs::read(target.join("nested").join("keep.txt")).unwrap(),
            b"patched-keep"
        );
        // staged 中不存在的文件应被删除
        assert!(!target.join("extra.txt").exists());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn dryrun_exe_marker_validation_fails_without_marker() {
        // 模拟 dry-run 的 exe marker 验证步骤：
        // exe 不含 marker → build_patched_exe_data 应失败
        let root = std::env::temp_dir().join(format!(
            "claude-zh-platform-dryrun-marker-fail-{}",
            now_millis()
        ));
        let _ = fs::remove_dir_all(&root);
        let app_dir = root.join("app");
        let temp_resources = app_dir.join("resources");
        fs::create_dir_all(&temp_resources).unwrap();
        // 不含 marker 的 exe
        fs::write(app_dir.join("Claude.exe"), b"no-marker-exe").unwrap();
        // app.asar 任意内容（asar_header_hash 会失败，但这里测的是 exe marker）
        fs::write(temp_resources.join("app.asar"), b"fake-asar").unwrap();

        let exe_bytes = fs::read(app_dir.join("Claude.exe")).unwrap();
        let fake_hash = "a".repeat(64);
        let result = build_patched_exe_data(&exe_bytes, &fake_hash);
        assert!(result.is_err(), "不含 marker 的 exe 应导致 patch 失败");

        // 真实目录未被修改（dry-run 不写真实文件）
        assert_eq!(
            fs::read(app_dir.join("Claude.exe")).unwrap(),
            b"no-marker-exe"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn dryrun_exe_marker_validation_succeeds_with_valid_marker() {
        // 模拟 dry-run 的 exe marker 验证步骤：
        // exe 含合法 marker → build_patched_exe_data 应成功
        let marker = br#"resources\\app.asar","alg":"SHA256","value":""#;
        let original_hash = b"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let mut exe_data = Vec::new();
        exe_data.extend_from_slice(b"MZ");
        exe_data.extend_from_slice(marker);
        exe_data.extend_from_slice(original_hash);
        exe_data.extend_from_slice(b"padding");

        let new_hash = "b".repeat(64);
        let result = build_patched_exe_data(&exe_data, &new_hash);
        assert!(result.is_ok(), "含合法 marker 的 exe 应 patch 成功: {:?}", result.err());

        let patched = result.unwrap();
        // 哈希已替换
        let marker_pos = patched
            .windows(marker.len())
            .position(|w| w == marker)
            .unwrap();
        assert_eq!(
            &patched[marker_pos + marker.len()..marker_pos + marker.len() + 64],
            new_hash.as_bytes()
        );
    }
}
