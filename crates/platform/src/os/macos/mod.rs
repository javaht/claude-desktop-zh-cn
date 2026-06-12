#![cfg(target_os = "macos")]

use chrono::Local;
use claude_zh_core::{
    err, install_into_resources, remove_path, set_config_locale, CoreError, InstallPaths,
    InstallRequest, LogSink, LogSinkExt, Result,
};
use std::{
    env,
    ffi::OsStr,
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Instant,
};
use uuid::Uuid;
use walkdir::WalkDir;

use crate::{environment::detect_claude, logging::run_command, paths::claude_config_paths};

fn quit_claude(logger: &dyn LogSink) {
    logger.info("正在请求 Claude Desktop 退出。");
    let _ = run_command(
        {
            let mut cmd = Command::new("osascript");
            cmd.arg("-e").arg(r#"tell application "Claude" to quit"#);
            cmd
        },
        logger,
        "关闭 Claude Desktop",
    );
}

pub(crate) fn launch_claude(path: &Path, logger: &dyn LogSink) {
    let _ = run_command(
        {
            let mut cmd = Command::new("open");
            cmd.arg("-a").arg(path);
            cmd
        },
        logger,
        "启动 Claude Desktop",
    );
}

fn macos_backup_candidates() -> Result<Vec<PathBuf>> {
    let mut backups: Vec<PathBuf> = fs::read_dir("/Applications")?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_dir()
                && path
                    .file_name()
                    .and_then(OsStr::to_str)
                    .is_some_and(|name| name.starts_with("Claude.backup-before-zh-CN-"))
        })
        .collect();
    backups.sort();
    Ok(backups)
}

fn macos_entitlements(path: &Path) -> Result<Option<plist::Dictionary>> {
    let output = Command::new("codesign")
        .arg("-d")
        .arg("--entitlements")
        .arg(":-")
        .arg("--xml")
        .arg(path)
        .output()?;
    if output.stdout.is_empty() {
        return Ok(None);
    }
    let value: plist::Value = plist::from_bytes(&output.stdout)?;
    match value {
        plist::Value::Dictionary(dict) => Ok(Some(dict)),
        _ => Ok(None),
    }
}

fn macos_has_entitlement(path: &Path, key: &str) -> bool {
    macos_entitlements(path)
        .ok()
        .flatten()
        .is_some_and(|ents| ents.contains_key(key))
}

fn macos_patch_source(app: &Path, logger: &dyn LogSink) -> Result<PathBuf> {
    const REQUIRED_ENTITLEMENT: &str = "com.apple.security.virtualization";
    if macos_has_entitlement(app, REQUIRED_ENTITLEMENT) {
        return Ok(app.to_path_buf());
    }

    logger.warn(
        "当前 Claude.app 缺少 virtualization entitlement，可能已经被粗签名破坏；尝试改用官方备份作为补丁源。",
    );
    for backup in macos_backup_candidates()? {
        if macos_has_entitlement(&backup, REQUIRED_ENTITLEMENT) {
            logger.info(format!("使用现有官方备份作为补丁源: {}", backup.display()));
            return Ok(backup);
        }
    }
    err("当前 Claude.app 缺少必要 entitlement，且没有找到可用官方备份。请先恢复或重装官方 Claude.app。")
}

fn copy_macos_app_to_temp(source: &Path, target: &Path, logger: &dyn LogSink) -> Result<()> {
    let mut cp = Command::new("cp");
    cp.args(["-cR"]).arg(source).arg(target);
    match run_command(cp, logger, "快速克隆 Claude.app 到临时目录") {
        Ok(_) => Ok(()),
        Err(error) => {
            logger.warn(format!("快速克隆失败，回退 ditto 完整复制: {error}"));
            if target.exists() {
                remove_path(target)?;
            }
            run_command(
                {
                    let mut cmd = Command::new("ditto");
                    cmd.arg(source).arg(target);
                    cmd
                },
                logger,
                "复制 Claude.app 到临时目录",
            )?;
            Ok(())
        }
    }
}

fn prepare_macos_temp_app_for_patch(app: &Path, logger: &dyn LogSink) -> Result<()> {
    let _ = run_command(
        {
            let mut cmd = Command::new("chflags");
            cmd.args(["-R", "nouchg,noschg"]).arg(app);
            cmd
        },
        logger,
        "清理临时 Claude.app 文件 flags",
    );
    run_command(
        {
            let mut cmd = Command::new("xattr");
            cmd.args(["-cr"]).arg(app);
            cmd
        },
        logger,
        "清理临时 Claude.app 扩展属性",
    )?;
    Ok(())
}

fn strip_and_augment_entitlements(ents: &mut plist::Dictionary) {
    ents.remove("com.apple.application-identifier");
    ents.remove("com.apple.developer.team-identifier");
    ents.remove("keychain-access-groups");
    ents.insert(
        "com.apple.security.cs.disable-library-validation".to_string(),
        plist::Value::Boolean(true),
    );
}

fn sign_macos_path(path: &Path) -> Result<()> {
    let mut command = Command::new("codesign");
    command.args([
        "--force",
        "--sign",
        "-",
        "--options",
        "runtime",
        "--preserve-metadata=identifier,flags",
    ]);

    let entitlement_path = if let Some(mut ents) = macos_entitlements(path)? {
        strip_and_augment_entitlements(&mut ents);
        let path = env::temp_dir().join(format!(
            "claude-zh-cn-entitlements-{}.plist",
            Uuid::new_v4()
        ));
        plist::Value::Dictionary(ents).to_file_xml(&path)?;
        command.arg("--entitlements").arg(&path);
        Some(path)
    } else {
        None
    };

    command.arg(path);
    let output = command
        .stderr(Stdio::piped())
        .stdout(Stdio::piped())
        .output()?;
    if let Some(path) = entitlement_path {
        let _ = fs::remove_file(path);
    }
    if !output.status.success() {
        let mut text = String::new();
        text.push_str(&crate::logging::decode_command_output(&output.stdout));
        text.push_str(&crate::logging::decode_command_output(&output.stderr));
        return err(format!("codesign 失败: {}\n{text}", path.display()));
    }
    Ok(())
}

fn macos_path_depth(path: &Path) -> usize {
    path.components().count()
}

fn is_macos_nested_bundle(path: &Path) -> bool {
    let Some(ext) = path.extension().and_then(OsStr::to_str) else {
        return false;
    };
    matches!(ext, "app" | "framework" | "bundle" | "xpc")
}

fn is_macos_signable_file(path: &Path) -> bool {
    if path.is_symlink() || !path.is_file() {
        return false;
    }
    if path
        .extension()
        .and_then(OsStr::to_str)
        .is_some_and(|ext| matches!(ext, "dylib" | "node" | "so"))
    {
        return true;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        return fs::metadata(path)
            .map(|meta| meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false);
    }
    #[allow(unreachable_code)]
    false
}

fn resign_macos_app(app: &Path, logger: &dyn LogSink) -> Result<()> {
    let started = Instant::now();
    let contents = app.join("Contents");
    logger.info("开始扫描 Claude.app 内部可签名文件。");

    let mut file_targets = Vec::new();
    let mut bundle_targets = Vec::new();
    for entry in WalkDir::new(&contents).follow_links(false) {
        let entry = entry?;
        let path = entry.path();
        if entry.file_type().is_dir() {
            if is_macos_nested_bundle(path) {
                bundle_targets.push(path.to_path_buf());
            }
        } else if entry.file_type().is_file() && is_macos_signable_file(path) {
            file_targets.push(path.to_path_buf());
        }
    }

    file_targets.sort_by_key(|path| std::cmp::Reverse(macos_path_depth(path)));
    bundle_targets.sort_by_key(|path| std::cmp::Reverse(macos_path_depth(path)));
    logger.info(format!(
        "需要重签名 {} 个可执行文件、{} 个嵌套 bundle。",
        file_targets.len(),
        bundle_targets.len()
    ));

    for (index, path) in file_targets.iter().enumerate() {
        sign_macos_path(path)?;
        let done = index + 1;
        if done % 25 == 0 || done == file_targets.len() {
            logger.info(format!("已重签名可执行文件: {done}/{}", file_targets.len()));
        }
    }
    for (index, path) in bundle_targets.iter().enumerate() {
        sign_macos_path(path)?;
        let done = index + 1;
        if done % 10 == 0 || done == bundle_targets.len() {
            logger.info(format!(
                "已重签名嵌套 bundle: {done}/{}",
                bundle_targets.len()
            ));
        }
    }
    sign_macos_path(app)?;
    logger.info(format!(
        "Claude.app 重签名完成，用时 {} 秒。",
        started.elapsed().as_secs()
    ));
    Ok(())
}

fn verify_macos_app_signature(app: &Path, logger: &dyn LogSink) -> Result<()> {
    run_command(
        {
            let mut cmd = Command::new("codesign");
            cmd.args(["--verify", "--deep", "--strict", "--verbose=2"]);
            cmd.arg(app);
            cmd
        },
        logger,
        "验证 Claude.app 签名",
    )?;
    if macos_has_entitlement(app, "com.apple.security.virtualization") {
        logger.info("已确认保留 virtualization entitlement。");
    } else {
        return err("重签名后缺少 virtualization entitlement。");
    }
    Ok(())
}

fn macos_temp_root() -> PathBuf {
    if crate::environment::is_admin() {
        PathBuf::from("/tmp")
    } else {
        env::temp_dir()
    }
}

pub(crate) fn platform_install_patch(
    resources: &Path,
    req: &InstallRequest,
    logger: &dyn LogSink,
) -> Result<()> {
    let (app, _resources_path, _) = detect_claude()
        .ok_or_else(|| CoreError::Message("未找到 /Applications/Claude.app。".to_string()))?;
    logger.info(format!("检测到 Claude.app: {}", app.display()));
    let source_app = macos_patch_source(&app, logger)?;
    if source_app != app {
        logger.info(format!("当前安装将从备份源复制: {}", source_app.display()));
    }
    if req.dry_run {
        logger.info("dry-run：不会关闭 Claude，也不会替换 /Applications/Claude.app。");
    } else {
        quit_claude(logger);
    }
    let tmp_root = macos_temp_root().join(format!(
        "claude-zh-cn-rs-{}",
        Local::now().format("%Y%m%d-%H%M%S")
    ));
    fs::create_dir_all(&tmp_root)?;
    let patched_app = tmp_root.join("Claude.app");
    logger.info(format!("临时工作目录: {}", tmp_root.display()));
    logger.info(format!(
        "正在复制 Claude.app 到临时目录: {}",
        patched_app.display()
    ));
    if patched_app.exists() {
        logger.info("临时 Claude.app 已存在，先清理旧副本。");
        remove_path(&patched_app)?;
    }
    copy_macos_app_to_temp(&source_app, &patched_app, logger)?;
    prepare_macos_temp_app_for_patch(&patched_app, logger)?;
    let patched_resources = patched_app.join("Contents/Resources");
    logger.info(format!(
        "开始写入中文资源和 app.asar 补丁: {}",
        patched_resources.display()
    ));
    install_into_resources(
        InstallPaths {
            source_resources: resources,
            target_resources: &patched_resources,
            mac_app_root: Some(&patched_app),
        },
        &req.language,
        &req.mode,
        None,
        logger,
    )?;
    logger.info("中文资源和 app.asar 补丁已写入临时 Claude.app。");
    logger.info("开始保留 entitlements 重签名临时 Claude.app。");
    resign_macos_app(&patched_app, logger)?;
    verify_macos_app_signature(&patched_app, logger)?;
    let _ = run_command(
        {
            let mut cmd = Command::new("xattr");
            cmd.args(["-dr", "com.apple.quarantine"]);
            cmd.arg(&patched_app);
            cmd
        },
        logger,
        "清理 quarantine 属性",
    );
    if req.dry_run {
        logger.info(format!(
            "dry-run 完成，临时 app 保留在: {}",
            patched_app.display()
        ));
        return Ok(());
    }
    logger.info("开始写入 Claude 语言配置。");
    for config in claude_config_paths() {
        set_config_locale(&config, &req.language, logger)?;
    }
    let backup = app.with_file_name(format!(
        "Claude.backup-before-zh-CN-{}.app",
        Local::now().format("%Y%m%d-%H%M%S")
    ));
    logger.info(format!(
        "准备替换正式 Claude.app，原始应用将备份到: {}",
        backup.display()
    ));
    fs::rename(&app, &backup)?;
    logger.info("原始 Claude.app 已移入备份。");
    fs::rename(&patched_app, &app)?;
    logger.info(format!("补丁版 Claude.app 已安装到: {}", app.display()));
    logger.info(format!("已备份原始 Claude.app: {}", backup.display()));
    if req.launch_after {
        launch_claude(&app, logger);
    }
    Ok(())
}

pub(crate) fn platform_restore_patch(dry_run: bool, logger: &dyn LogSink) -> Result<()> {
    if dry_run {
        // 步骤 1: 扫描备份
        let backups = match macos_backup_candidates() {
            Ok(b) => b,
            Err(e) => {
                logger.warn(format!("dry-run 预诊：扫描备份失败: {e}"));
                return Ok(());
            }
        };
        if backups.is_empty() {
            logger.warn("dry-run 预诊：未找到任何官方备份，真实卸载会失败。请先重装官方 Claude Desktop。");
            return Ok(());
        }
        logger.info(format!("dry-run 预诊：找到 {} 个官方备份。", backups.len()));
        for path in &backups {
            logger.info(format!("  - {}", path.display()));
        }

        // 步骤 2: 报告将恢复的备份（取最新备份，排序后最后一个，与 Windows 行为一致）
        let backup = backups.last().unwrap();
        logger.info(format!("dry-run 预诊：将恢复备份: {}", backup.display()));

        // 步骤 3: 检测 Claude 进程
        if let Ok(output) = Command::new("pgrep").arg("-x").arg("Claude").output() {
            if output.status.success() {
                logger.warn("dry-run 预诊：Claude Desktop 正在运行，真实卸载会先关闭它。");
            } else {
                logger.info("dry-run 预诊：Claude Desktop 当前未运行。");
            }
        }

        // 步骤 4: 检测 /Applications/Claude.app 路径
        let app_path = PathBuf::from("/Applications/Claude.app");
        if app_path.exists() {
            logger.info("dry-run 预诊：当前 Claude.app 存在，真实卸载会先移到临时路径再清理。");
        } else {
            logger.info("dry-run 预诊：当前 Claude.app 不存在，将直接 rename 备份到该位置。");
        }

        // 步骤 5: /Applications 可写性（基于 metadata 的粗略判断）
        match fs::metadata("/Applications") {
            Ok(meta) => {
                if meta.permissions().readonly() {
                    logger.info("dry-run 预诊：当前进程对 /Applications 无写权限（基于 metadata 的粗略判断）；非 dry-run 会走管理员授权后写入。");
                } else {
                    logger.info("dry-run 预诊：当前进程对 /Applications 有写权限（基于 metadata 的粗略判断）。");
                }
            }
            Err(e) => {
                logger.warn(format!(
                    "dry-run 预诊：无法读取 /Applications 元数据（{e}），无法判断写权限。"
                ));
            }
        }

        // 步骤 6: 备份完整性
        if backup.is_dir() {
            logger.info("dry-run 预诊：备份目录完整可读。");
        } else {
            logger.warn("dry-run 预诊：备份不是有效目录，真实卸载可能失败。");
        }

        // 步骤 7: 旧备份清理
        let stale = backups.len().saturating_sub(1);
        if stale > 0 {
            logger.info(format!("dry-run 预诊：将清理 {} 个旧备份。", stale));
            for path in backups.iter().take(backups.len().saturating_sub(1)) {
                logger.info(format!("  - {}", path.display()));
            }
        }

        // 步骤 8: locale 预演
        for path in claude_config_paths() {
            if path.exists() {
                logger.info(format!("dry-run 预诊：config 存在: {}", path.display()));
            } else {
                logger.info(format!(
                    "dry-run 预诊：config 不存在，真实卸载会新建: {}",
                    path.display()
                ));
            }
        }
        let cur = crate::environment::current_locale().unwrap_or_else(|| "<未设置>".to_string());
        logger.info(format!("dry-run 预诊：当前 locale = {cur} → 将改为 en-US"));

        // 步骤 9: 收尾
        logger.info("dry-run 预诊完成：未修改任何文件。");
        return Ok(());
    }
    let app = PathBuf::from("/Applications/Claude.app");
    logger.info("正在查找 macOS Claude.app 备份。");
    let mut backups: Vec<PathBuf> = fs::read_dir("/Applications")?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_dir()
                && path
                    .file_name()
                    .and_then(OsStr::to_str)
                    .is_some_and(|name| name.starts_with("Claude.backup-before-zh-CN-"))
        })
        .collect();
    backups.sort();
    // 取最新备份（排序后最后一个），与 Windows 行为一致
    let Some(backup) = backups.last().cloned() else {
        return err("没有找到可恢复的 Claude 备份。");
    };
    logger.info(format!("将恢复备份: {}", backup.display()));
    quit_claude(logger);
    let current_tmp = app.with_file_name(format!(
        "Claude.restore-current-{}.app",
        Local::now().format("%Y%m%d-%H%M%S")
    ));
    if app.exists() {
        logger.info(format!(
            "当前 Claude.app 临时移动到: {}",
            current_tmp.display()
        ));
        fs::rename(&app, &current_tmp)?;
    }
    fs::rename(&backup, &app)?;
    logger.info(format!("官方 Claude.app 已恢复到: {}", app.display()));
    if current_tmp.exists() {
        logger.info("正在清理恢复前的补丁版 Claude.app。");
        remove_path(&current_tmp)?;
    }
    // backups 已升序排序，last() 是最新（已用于恢复），跳过最新只清理其余旧备份
    let total = backups.len();
    for extra in backups.into_iter().take(total.saturating_sub(1)) {
        logger.info(format!("正在清理旧备份: {}", extra.display()));
        let _ = remove_path(&extra);
    }
    logger.info("正在恢复英文语言配置。");
    for config in claude_config_paths() {
        set_config_locale(&config, "en-US", logger)?;
    }
    logger.info("macOS 恢复完成。");
    Ok(())
}
