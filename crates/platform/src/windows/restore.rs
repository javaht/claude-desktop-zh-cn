#![cfg(windows)]

use claude_zh_core::{
    copy_file, err, remove_language_files, remove_path, set_config_locale, unregister_language,
    CoreError, LogSink, LogSinkExt, Result,
};
use std::{
    collections::HashMap,
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::Duration,
};
use walkdir::WalkDir;

use crate::{
    environment::detect_claude,
    logging::{decode_command_output, hide_command_window},
    paths::claude_config_paths,
};

use super::backup::windows_latest_pristine_backup;
use super::permissions::{acquire_windowsapps_permission, windowsapps_permission_targets};

struct DryRunSyncStats {
    to_add: usize,
    to_overwrite: usize,
    to_delete: usize,
    to_keep: usize,
}

fn dry_run_sync_dir_stats(src: &Path, dst: &Path) -> Result<DryRunSyncStats> {
    let mut src_files: HashMap<PathBuf, u64> = HashMap::new();
    if src.is_dir() {
        for e in WalkDir::new(src) {
            let e = e?;
            if e.file_type().is_file() {
                let rel = e.path().strip_prefix(src).unwrap().to_path_buf();
                src_files.insert(rel, e.metadata()?.len());
            }
        }
    }
    let mut dst_files: HashMap<PathBuf, u64> = HashMap::new();
    if dst.is_dir() {
        for e in WalkDir::new(dst) {
            let e = e?;
            if e.file_type().is_file() {
                let rel = e.path().strip_prefix(dst).unwrap().to_path_buf();
                dst_files.insert(rel, e.metadata()?.len());
            }
        }
    }
    let mut to_add = 0;
    let mut to_overwrite = 0;
    let mut to_keep = 0;
    for (rel, src_len) in &src_files {
        match dst_files.get(rel) {
            None => to_add += 1,
            Some(dst_len) if dst_len == src_len => to_keep += 1,
            Some(_) => to_overwrite += 1,
        }
    }
    let to_delete = dst_files
        .keys()
        .filter(|k| !src_files.contains_key(*k))
        .count();
    Ok(DryRunSyncStats {
        to_add,
        to_overwrite,
        to_delete,
        to_keep,
    })
}

fn dry_run_remove_language_files_check(resources: &Path) -> Vec<PathBuf> {
    let langs = ["zh-CN", "zh-TW", "zh-HK"];
    let mut existing = Vec::new();
    for lang in langs {
        let candidates = [
            resources.join(format!("{lang}.json")),
            resources
                .join("ion-dist")
                .join("i18n")
                .join(format!("{lang}.json")),
            resources
                .join("ion-dist")
                .join("i18n")
                .join("statsig")
                .join(format!("{lang}.json")),
        ];
        for c in candidates {
            if c.exists() {
                existing.push(c);
            }
        }
    }
    existing
}

fn dry_run_unregister_language_check(resources: &Path) -> Vec<PathBuf> {
    // 仅统计 ion-dist/assets/v1 下的 .js 文件数量；不做正则匹配（避免重复 core 的实现）
    // 真正"哪些会改"需要跑正则，这里只给上限提示，让用户知道 JS 注册会被扫
    let dir = resources.join("ion-dist").join("assets").join("v1");
    if !dir.is_dir() {
        return Vec::new();
    }
    let mut files = Vec::new();
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() && path.extension().is_some_and(|ext| ext == "js") {
                files.push(path);
            }
        }
    }
    files
}

fn sync_dir_exact(src: &Path, dst: &Path, logger: &dyn LogSink) -> Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(dst)? {
        let entry = entry?;
        let target = entry.path();
        let source = src.join(entry.file_name());
        if !source.exists() {
            remove_path(&target)?;
        }
    }
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let source = entry.path();
        let target = dst.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            sync_dir_exact(&source, &target, logger)?;
        } else if entry.file_type()?.is_file() {
            copy_windows_file_with_retries(&source, &target, logger, "同步资源文件").map_err(
                |error| {
                    CoreError::Message(format!(
                        "同步资源文件失败: {} -> {}: {error}",
                        source.display(),
                        target.display()
                    ))
                },
            )?;
        }
    }
    Ok(())
}

pub(super) fn cleanup_windows_restore_artifacts(app_dir: &Path, logger: &dyn LogSink) -> Result<()> {
    if !app_dir.is_dir() {
        return Ok(());
    }
    let mut removed = 0usize;
    for entry in fs::read_dir(app_dir)? {
        let entry = entry?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let is_stale_restore_artifact = name.starts_with("resources.restore-current-")
            || (name.starts_with("Claude.restore-current-") && name.ends_with(".exe"));
        if !is_stale_restore_artifact {
            continue;
        }
        remove_path(&path)?;
        removed += 1;
    }
    if removed > 0 {
        logger.info(format!("已清理 {removed} 个旧的 Windows 恢复临时文件。"));
    }
    Ok(())
}

pub(super) fn try_cleanup_windows_restore_artifacts(app_dir: &Path, logger: &dyn LogSink) {
    if let Err(error) = cleanup_windows_restore_artifacts(app_dir, logger) {
        logger.warn(format!(
            "清理旧的 Windows 恢复临时文件失败，将保留残留以避免影响主流程: {error}"
        ));
    }
}

fn copy_windows_file_with_retries(
    src: &Path,
    dst: &Path,
    logger: &dyn LogSink,
    context: &str,
) -> Result<()> {
    const RETRY_DELAYS_MS: [u64; 6] = [150, 300, 500, 800, 1200, 1800];
    let mut last_error = None;

    for (attempt, delay_ms) in RETRY_DELAYS_MS.iter().enumerate() {
        match copy_file(src, dst) {
            Ok(()) => {
                if attempt > 0 {
                    logger.info(format!("{context} 在第 {} 次重试后成功。", attempt + 1));
                }
                return Ok(());
            }
            Err(CoreError::Io(error))
                if matches!(
                    error.kind(),
                    ErrorKind::PermissionDenied | ErrorKind::WouldBlock
                ) =>
            {
                logger.warn(format!(
                    "{context} 失败（第 {} 次）: {error}；等待 {delay_ms}ms 后重试。",
                    attempt + 1
                ));
                last_error = Some(CoreError::Io(error));
                super::quit_claude(logger);
                thread::sleep(Duration::from_millis(*delay_ms));
            }
            Err(error) => return Err(error),
        }
    }

    match copy_file(src, dst) {
        Ok(()) => Ok(()),
        Err(error) => Err(CoreError::Message(format!(
            "{context} 最终失败: {} -> {}: {}",
            src.display(),
            dst.display(),
            last_error.unwrap_or(error)
        ))),
    }
}

fn restore_windows_backup(app: &Path, resources: &Path, logger: &dyn LogSink) -> Result<()> {
    if let Some(snapshot) = windows_latest_pristine_backup(app)? {
        logger.info(format!("将从包外纯净备份恢复: {}", snapshot.display()));
        let app_dir = resources
            .parent()
            .ok_or_else(|| CoreError::Message("resources 路径无父目录。".to_string()))?;
        return restore_windows_backup_from_snapshot(&snapshot, app_dir, resources, logger);
    }
    logger.warn("没有找到包外纯净备份，尝试旧版包内备份。");
    if restore_windows_legacy_backup(resources, logger)? {
        return Ok(());
    }
    err("未找到可用的官方备份，无法恢复。请先重装官方 Claude Desktop。")
}

pub(super) fn restore_windows_backup_from_snapshot(
    snapshot: &Path,
    app_dir: &Path,
    resources: &Path,
    logger: &dyn LogSink,
) -> Result<()> {
    let backup_resources = snapshot.join("app").join("resources");
    let backup_exe = snapshot.join("app").join("Claude.exe");
    if !backup_resources.is_dir() || !backup_exe.is_file() {
        return err(format!("纯净备份不完整: {}", snapshot.display()));
    }
    sync_dir_exact(&backup_resources, resources, logger)?;
    copy_windows_file_with_retries(
        &backup_exe,
        &app_dir.join("Claude.exe"),
        logger,
        "恢复 Claude.exe",
    )?;
    try_cleanup_windows_restore_artifacts(app_dir, logger);
    logger.info("已从包外纯净备份恢复官方文件。");
    Ok(())
}

fn restore_windows_legacy_backup(resources: &Path, logger: &dyn LogSink) -> Result<bool> {
    let root = resources.join(".zh-cn-backups");
    logger.info(format!("正在查找 Windows 资源备份: {}", root.display()));
    let Some(entries) = fs::read_dir(&root).ok() else {
        logger.warn("没有找到 Windows 包内备份。");
        return Ok(false);
    };
    let mut backups: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect();
    backups.sort();
    let Some(backup) = backups.pop() else {
        logger.warn("没有找到 Windows 包内备份。");
        return Ok(false);
    };
    logger.info(format!("将恢复 Windows 资源备份: {}", backup.display()));
    for entry in WalkDir::new(&backup) {
        let entry = entry?;
        if !entry.file_type().is_file() {
            continue;
        }
        let rel = entry.path().strip_prefix(&backup).unwrap();
        copy_file(entry.path(), &resources.join(rel))?;
        logger.info(format!("已恢复: {}", rel.display()));
    }
    remove_path(&root)?;
    logger.info("已清理 Windows 资源备份目录。");
    Ok(true)
}

pub(crate) fn platform_restore_patch(dry_run: bool, logger: &dyn LogSink) -> Result<()> {
    if dry_run {
        // Step 1: 检测 Claude 安装
        let (app, resources, _) = detect_claude().ok_or_else(|| {
            CoreError::Message("dry-run 预诊：未找到 Claude Desktop。真实卸载会失败。".to_string())
        })?;
        logger.info(format!(
            "dry-run 预诊：Claude Desktop 路径 = {}",
            app.display()
        ));
        logger.info(format!(
            "dry-run 预诊：目标 resources = {}",
            resources.display()
        ));

        // Step 2: 检测 Claude 进程
        {
            let mut cmd = Command::new("powershell.exe");
            let script = super::windows_claude_probe_script();
            cmd.args([
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                script.as_str(),
            ]);
            hide_command_window(&mut cmd);
            match cmd.output() {
                Ok(out) => {
                    let text = decode_command_output(&out.stdout);
                    let first_line = text.lines().next().unwrap_or("");
                    if first_line == "NONE" {
                        logger.info("dry-run 预诊：Claude Desktop 当前未运行。");
                    } else if let Some(rest) = first_line.strip_prefix("FOUND:") {
                        let n: usize = rest.trim().parse().unwrap_or(0);
                        logger.warn(format!(
                            "dry-run 预诊：检测到 {} 个 Claude Desktop 进程，真实卸载会先关闭它们。",
                            n
                        ));
                        for line in text.lines().skip(1) {
                            logger.info(line);
                        }
                    }
                }
                Err(_) => {
                    logger.warn("dry-run 预诊：进程探测失败，跳过。");
                }
            }
        }

        // Step 3: WindowsApps 权限
        let perm_targets = windowsapps_permission_targets(&resources);
        if perm_targets.is_empty() {
            logger.info("dry-run 预诊：非 WindowsApps 安装，无需获取额外权限。");
        } else {
            logger.warn(
                "dry-run 预诊：WindowsApps 安装，真实卸载需要 takeown + icacls 提权下列路径：",
            );
            for p in &perm_targets {
                logger.info(format!("  - {}", p.display()));
            }
        }

        // Step 4: 备份检测
        let pristine = match windows_latest_pristine_backup(&app) {
            Ok(opt) => opt,
            Err(e) => {
                logger.warn(format!("dry-run 预诊：读取包外纯净备份目录失败（{e}），降级检查 legacy 备份。"));
                None
            }
        };
        let mut snapshot_for_diff: Option<PathBuf> = None;
        match pristine {
            Some(snap) => {
                logger.info(format!(
                    "dry-run 预诊：找到包外纯净备份: {}",
                    snap.display()
                ));
                let res_dir = snap.join("app").join("resources");
                let exe = snap.join("app").join("Claude.exe");
                if res_dir.is_dir() && exe.is_file() {
                    logger.info("dry-run 预诊：备份完整可用。");
                    snapshot_for_diff = Some(snap);
                } else {
                    logger.warn(format!(
                        "dry-run 预诊：纯净备份不完整: {}，真实卸载会失败。",
                        snap.display()
                    ));
                }
            }
            None => {
                let legacy = resources.join(".zh-cn-backups");
                let legacy_has = legacy.is_dir()
                    && fs::read_dir(&legacy)
                        .map(|it| it.flatten().any(|e| e.path().is_dir()))
                        .unwrap_or(false);
                if legacy_has {
                    logger.info(
                        "dry-run 预诊：未找到包外纯净备份，将使用包内 legacy 备份。",
                    );
                } else {
                    logger.warn(
                        "dry-run 预诊：未找到任何备份，真实卸载会失败。请先重装官方 Claude Desktop。",
                    );
                    return Ok(());
                }
            }
        }

        // Step 5: 文件 diff 预演（仅有 pristine snapshot 时）
        if let Some(snap) = &snapshot_for_diff {
            let snap_res = snap.join("app").join("resources");
            match dry_run_sync_dir_stats(&snap_res, &resources) {
                Ok(s) => logger.info(format!(
                    "dry-run 预诊：备份恢复将新增 {} 个文件、覆盖 {} 个文件、删除 {} 个文件、保留 {} 个文件。",
                    s.to_add, s.to_overwrite, s.to_delete, s.to_keep
                )),
                Err(e) => logger.warn(format!("dry-run 预诊：文件 diff 统计失败：{e}")),
            }
        }

        // Step 6: 语言文件删除预演
        let existing = dry_run_remove_language_files_check(&resources);
        logger.info(format!(
            "dry-run 预诊：将删除 {} 个中文语言文件。",
            existing.len()
        ));
        for p in &existing {
            logger.info(format!("  - {}", p.display()));
        }

        // Step 6.5: JS 语言注册取消预演
        let js_files = dry_run_unregister_language_check(&resources);
        if js_files.is_empty() {
            logger.info("dry-run 预诊：未找到 ion-dist/assets/v1 下的 JS 文件，无需取消语言注册。");
        } else {
            logger.info(format!("dry-run 预诊：将扫描 {} 个 JS 文件并尝试取消中文语言注册（仅匹配的文件会被改写）。", js_files.len()));
        }

        // Step 7: locale 预演
        for cfg in claude_config_paths() {
            if cfg.exists() {
                logger.info(format!("dry-run 预诊：config 存在: {}", cfg.display()));
            } else {
                logger.info(format!(
                    "dry-run 预诊：config 不存在，真实卸载会新建: {}",
                    cfg.display()
                ));
            }
        }
        let cur = crate::environment::current_locale().unwrap_or_else(|| "<未设置>".to_string());
        logger.info(format!(
            "dry-run 预诊：当前 locale = {cur} → 将改为 en-US"
        ));

        // Step 8: 更新守护计划任务
        {
            let mut cmd = Command::new("schtasks");
            hide_command_window(&mut cmd);
            cmd.args(["/Query", "/TN", super::WATCHER_TASK])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            match cmd.status() {
                Ok(s) if s.success() => {
                    logger.info("dry-run 预诊：找到更新守护计划任务，真实卸载会删除它。")
                }
                Ok(_) => logger.info("dry-run 预诊：未找到更新守护计划任务。"),
                Err(e) => logger.warn(format!("dry-run 预诊：schtasks 命令执行失败（{e}），无法判断计划任务状态。")),
            }
        }

        // Step 9: 收尾
        logger.info("dry-run 预诊完成：未修改任何文件。");
        return Ok(());
    }
    let (app, resources, _) =
        detect_claude().ok_or_else(|| CoreError::Message("未找到 Claude Desktop。".to_string()))?;
    logger.info(format!(
        "Windows 恢复目标 resources: {}",
        resources.display()
    ));
    super::quit_claude(logger);
    for path in windowsapps_permission_targets(&resources) {
        acquire_windowsapps_permission(&path, logger)?;
    }
    restore_windows_backup(&app, &resources, logger)?;
    logger.info("正在删除中文语言资源文件。");
    remove_language_files(&resources)?;
    unregister_language(&resources, logger)?;
    logger.info("正在恢复英文语言配置。");
    for config in claude_config_paths() {
        set_config_locale(&config, "en-US", logger)?;
    }
    let _ = super::unregister_update_watcher(logger);
    logger.info("Windows 恢复完成。");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        cleanup_windows_restore_artifacts, restore_windows_backup_from_snapshot, sync_dir_exact,
    };
    use claude_zh_core::{now_millis, NoopLogger};
    use std::{fs, io::Write, sync::Arc, thread, time::Duration};

    #[test]
    fn restore_windows_backup_from_snapshot_replaces_resources_and_exe() {
        let root = std::env::temp_dir().join(format!(
            "claude-zh-platform-restore-snapshot-{}",
            now_millis()
        ));
        let _ = fs::remove_dir_all(&root);
        let app_dir = root.join("app");
        let resources = app_dir.join("resources");
        let snapshot = root.join("snapshot");
        fs::create_dir_all(resources.join("nested")).unwrap();
        fs::create_dir_all(snapshot.join("app").join("resources").join("nested")).unwrap();
        fs::write(app_dir.join("Claude.exe"), b"patched-exe").unwrap();
        fs::write(
            app_dir.join("Claude.restore-current-20260609-124541.exe"),
            b"stale-exe",
        )
        .unwrap();
        fs::create_dir_all(app_dir.join("resources.restore-current-20260609-124541")).unwrap();
        fs::write(resources.join("app.asar"), b"patched-asar").unwrap();
        fs::write(resources.join("zh-CN.json"), b"patched-lang").unwrap();
        fs::write(snapshot.join("app").join("Claude.exe"), b"clean-exe").unwrap();
        fs::write(
            snapshot.join("app").join("resources").join("app.asar"),
            b"clean-asar",
        )
        .unwrap();
        fs::write(
            snapshot
                .join("app")
                .join("resources")
                .join("nested")
                .join("keep.txt"),
            b"clean-file",
        )
        .unwrap();

        restore_windows_backup_from_snapshot(&snapshot, &app_dir, &resources, &NoopLogger).unwrap();

        assert_eq!(fs::read(app_dir.join("Claude.exe")).unwrap(), b"clean-exe");
        assert_eq!(fs::read(resources.join("app.asar")).unwrap(), b"clean-asar");
        assert!(!resources.join("zh-CN.json").exists());
        assert!(!app_dir
            .join("Claude.restore-current-20260609-124541.exe")
            .exists());
        assert!(!app_dir
            .join("resources.restore-current-20260609-124541")
            .exists());
        assert_eq!(
            fs::read(resources.join("nested").join("keep.txt")).unwrap(),
            b"clean-file"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn restore_windows_backup_from_snapshot_retries_when_exe_is_temporarily_locked() {
        let root =
            std::env::temp_dir().join(format!("claude-zh-platform-restore-retry-{}", now_millis()));
        let _ = fs::remove_dir_all(&root);
        let app_dir = root.join("app");
        let resources = app_dir.join("resources");
        let snapshot = root.join("snapshot");
        fs::create_dir_all(&resources).unwrap();
        fs::create_dir_all(snapshot.join("app").join("resources")).unwrap();
        fs::write(app_dir.join("Claude.exe"), b"patched-exe").unwrap();
        fs::write(resources.join("app.asar"), b"patched-asar").unwrap();
        fs::write(
            snapshot.join("app").join("Claude.exe"),
            b"clean-exe-after-retry",
        )
        .unwrap();
        fs::write(
            snapshot.join("app").join("resources").join("app.asar"),
            b"clean-asar",
        )
        .unwrap();

        let exe_path = app_dir.join("Claude.exe");
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&exe_path)
            .unwrap();
        let writer = Arc::new(file);
        let mut writer_clone = Arc::clone(&writer);
        let hold = thread::spawn(move || {
            writer_clone.write_all(b"").unwrap();
            thread::sleep(Duration::from_millis(650));
        });

        restore_windows_backup_from_snapshot(&snapshot, &app_dir, &resources, &NoopLogger).unwrap();
        hold.join().unwrap();

        assert_eq!(
            fs::read(app_dir.join("Claude.exe")).unwrap(),
            b"clean-exe-after-retry"
        );
        assert_eq!(fs::read(resources.join("app.asar")).unwrap(), b"clean-asar");

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn sync_dir_exact_removes_extra_entries_and_restores_expected_files() {
        let root = std::env::temp_dir().join(format!(
            "claude-zh-platform-sync-dir-exact-{}",
            now_millis()
        ));
        let _ = fs::remove_dir_all(&root);
        let src = root.join("src");
        let dst = root.join("dst");
        fs::create_dir_all(src.join("nested")).unwrap();
        fs::create_dir_all(dst.join("extra-dir")).unwrap();
        fs::write(src.join("same.txt"), b"clean").unwrap();
        fs::write(src.join("nested").join("keep.txt"), b"keep").unwrap();
        fs::write(dst.join("same.txt"), b"patched").unwrap();
        fs::write(dst.join("extra.txt"), b"extra").unwrap();
        fs::write(dst.join("extra-dir").join("extra.txt"), b"extra").unwrap();

        sync_dir_exact(&src, &dst, &NoopLogger).unwrap();

        assert_eq!(fs::read(dst.join("same.txt")).unwrap(), b"clean");
        assert_eq!(
            fs::read(dst.join("nested").join("keep.txt")).unwrap(),
            b"keep"
        );
        assert!(!dst.join("extra.txt").exists());
        assert!(!dst.join("extra-dir").exists());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn cleanup_windows_restore_artifacts_removes_only_stale_restore_entries() {
        let root = std::env::temp_dir().join(format!(
            "claude-zh-platform-cleanup-restore-artifacts-{}",
            now_millis()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("resources.restore-current-20260609-124541")).unwrap();
        fs::write(
            root.join("Claude.restore-current-20260609-124541.exe"),
            b"stale-exe",
        )
        .unwrap();
        fs::write(root.join("Claude.exe"), b"real-exe").unwrap();
        fs::create_dir_all(root.join("resources")).unwrap();

        cleanup_windows_restore_artifacts(&root, &NoopLogger).unwrap();

        assert!(!root
            .join("resources.restore-current-20260609-124541")
            .exists());
        assert!(!root
            .join("Claude.restore-current-20260609-124541.exe")
            .exists());
        assert!(root.join("Claude.exe").exists());
        assert!(root.join("resources").exists());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn cleanup_windows_restore_artifacts_removes_readonly_stale_restore_entries() {
        let root = std::env::temp_dir().join(format!(
            "claude-zh-platform-cleanup-readonly-restore-artifacts-{}",
            now_millis()
        ));
        let stale_dir = root.join("resources.restore-current-20260609-124541");
        let stale_file = stale_dir.join("readonly.txt");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&stale_dir).unwrap();
        fs::write(&stale_file, b"stale").unwrap();
        let mut permissions = fs::metadata(&stale_file).unwrap().permissions();
        permissions.set_readonly(true);
        fs::set_permissions(&stale_file, permissions).unwrap();

        cleanup_windows_restore_artifacts(&root, &NoopLogger).unwrap();

        assert!(!stale_dir.exists());

        let _ = fs::remove_dir_all(&root);
    }
}
