use chrono::Local;
#[cfg(windows)]
use claude_zh_core::copy_file;
#[cfg(windows)]
use claude_zh_core::write_json;
#[cfg(windows)]
use claude_zh_core::{
    asar_header_hash, patched_version_record, remove_language_files, unregister_language,
};
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
#[cfg(windows)]
use std::{io::ErrorKind, thread, time::Duration};
#[cfg(target_os = "macos")]
use uuid::Uuid;
use walkdir::WalkDir;

#[cfg(windows)]
use crate::logging::hide_command_window;
use crate::{environment::detect_claude, logging::run_command, paths::claude_config_paths};

#[cfg(windows)]
const WATCHER_TASK: &str = "ClaudeDesktopZhCn-UpdateWatcher";

#[cfg(target_os = "macos")]
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

#[cfg(windows)]
const WINDOWS_CLAUDE_PROCESS_TREE_FUNCTION: &str = r#"
function Get-ClaudeDesktopProcessTree {
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ExecutablePath -and
      (
        $_.ExecutablePath -like '*\WindowsApps\Claude_*' -or
        $_.ExecutablePath -like '*\AnthropicClaude\app-*\*'
      )
    })
  if (-not $all) {
    return @()
  }

  $anchors = @($all)
  if (-not $anchors) {
    return @()
  }

  $selected = @{}
  foreach ($proc in $anchors) {
    $selected[[int]$proc.ProcessId] = $true
  }

  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($proc in $all) {
      $procId = [int]$proc.ProcessId
      $parentId = [int]$proc.ParentProcessId
      if ($selected.ContainsKey($procId) -or $selected.ContainsKey($parentId)) {
        if (-not $selected.ContainsKey($procId)) {
          $selected[$procId] = $true
          $changed = $true
        }
        if ($parentId -ne 0 -and -not $selected.ContainsKey($parentId)) {
          $parent = $all | Where-Object { [int]$_.ProcessId -eq $parentId } | Select-Object -First 1
          if ($parent) {
            $selected[$parentId] = $true
            $changed = $true
          }
        }
      }
    }
  }

  @($all | Where-Object { $selected.ContainsKey([int]$_.ProcessId) })
}
"#;

#[cfg(windows)]
fn windows_claude_stop_script() -> String {
    format!(
        "{}\nGet-ClaudeDesktopProcessTree |\n  ForEach-Object {{\n    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue\n  }}\n",
        WINDOWS_CLAUDE_PROCESS_TREE_FUNCTION
    )
}

#[cfg(windows)]
fn windows_claude_probe_script() -> String {
    format!(
        "{}\n$procs = @(Get-ClaudeDesktopProcessTree)\nif ($procs.Count -gt 0) {{\n  Write-Output (\"FOUND:\" + $procs.Count)\n  $procs | ForEach-Object {{ Write-Output (\" - PID=\" + $_.ProcessId + \" EXE=\" + $_.ExecutablePath) }}\n}} else {{\n  Write-Output \"NONE\"\n}}\n",
        WINDOWS_CLAUDE_PROCESS_TREE_FUNCTION
    )
}

#[cfg(windows)]
fn quit_claude(logger: &dyn LogSink) {
    logger.info("正在关闭 Claude Desktop 进程。");
    // 使用 PowerShell 精确匹配已知安装路径，避免误杀 Claude Code CLI
    let mut cmd = Command::new("powershell.exe");
    let script = windows_claude_stop_script();
    cmd.args([
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        script.as_str(),
    ]);
    hide_command_window(&mut cmd);
    let _ = run_command(cmd, logger, "关闭 Claude Desktop");
}

#[cfg(not(any(target_os = "macos", windows)))]
fn quit_claude(_logger: &dyn LogSink) {}

#[cfg(target_os = "macos")]
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

#[cfg(windows)]
pub(crate) fn launch_claude(app: &Path, logger: &dyn LogSink) {
    let exe = [
        "Claude.exe",
        "claude.exe",
        r"app\Claude.exe",
        r"app\claude.exe",
    ]
    .iter()
    .map(|name| app.join(name))
    .find(|path| path.is_file());
    if let Some(exe) = exe {
        let mut cmd = Command::new(exe);
        hide_command_window(&mut cmd);
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let _ = cmd.spawn();
        logger.info("已启动 Claude Desktop");
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
pub(crate) fn launch_claude(_app: &Path, _logger: &dyn LogSink) {}

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
fn macos_has_entitlement(path: &Path, key: &str) -> bool {
    macos_entitlements(path)
        .ok()
        .flatten()
        .is_some_and(|ents| ents.contains_key(key))
}

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
fn strip_and_augment_entitlements(ents: &mut plist::Dictionary) {
    ents.remove("com.apple.application-identifier");
    ents.remove("com.apple.developer.team-identifier");
    ents.remove("keychain-access-groups");
    ents.insert(
        "com.apple.security.cs.disable-library-validation".to_string(),
        plist::Value::Boolean(true),
    );
}

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
fn macos_path_depth(path: &Path) -> usize {
    path.components().count()
}

#[cfg(target_os = "macos")]
fn is_macos_nested_bundle(path: &Path) -> bool {
    let Some(ext) = path.extension().and_then(OsStr::to_str) else {
        return false;
    };
    matches!(ext, "app" | "framework" | "bundle" | "xpc")
}

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
fn macos_temp_root() -> PathBuf {
    if crate::environment::is_admin() {
        PathBuf::from("/tmp")
    } else {
        env::temp_dir()
    }
}

#[cfg(target_os = "macos")]
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

#[cfg(windows)]
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
    quit_claude(logger);
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
        let _ = unregister_update_watcher(logger);
        if req.launch_after {
            launch_claude(&app, logger);
        }
        Ok(())
    })();
    if let Err(error) = install_result {
        logger.error(format!("安装失败，正在尝试从纯净备份恢复官方文件：{error}"));
        let app_dir = target_resources
            .parent()
            .ok_or_else(|| CoreError::Message("resources 路径无父目录。".to_string()))?;
        let _ = restore_windows_backup_from_snapshot(
            &pristine_backup,
            app_dir,
            &target_resources,
            logger,
        );
        for config in claude_config_paths() {
            let _ = set_config_locale(&config, "en-US", logger);
        }
        return Err(error);
    }
    Ok(())
}

#[cfg(windows)]
fn windowsapps_permission_targets(resources: &Path) -> Vec<PathBuf> {
    if resources.starts_with(r"C:\Program Files\WindowsApps") {
        let mut targets = vec![resources.to_path_buf()];
        if let Some(app_dir) = resources.parent() {
            targets.push(app_dir.to_path_buf());
        }
        targets
    } else {
        Vec::new()
    }
}

#[cfg(windows)]
fn windows_external_backup_root() -> Result<PathBuf> {
    let Some(local) = dirs::data_local_dir() else {
        return err("未找到 LocalAppData，无法创建 Windows 包外备份。");
    };
    Ok(local.join("ClaudeDesktopZhCn").join("pristine-backups"))
}

#[cfg(windows)]
fn windows_external_backup_prefix(app: &Path) -> Result<String> {
    app.file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.to_string())
        .ok_or_else(|| CoreError::Message(format!("无法识别安装目录名: {}", app.display())))
}

#[cfg(windows)]
fn windows_latest_pristine_backup(app: &Path) -> Result<Option<PathBuf>> {
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

#[cfg(windows)]
fn windows_resources_look_patched(resources: &Path) -> bool {
    resources.join("zh-CN.json").exists()
        || resources.join("zh-CN.lproj").exists()
        || resources.join("zh_CN.lproj").exists()
}

#[cfg(windows)]
struct DryRunSyncStats {
    to_add: usize,
    to_overwrite: usize,
    to_delete: usize,
    to_keep: usize,
}

#[cfg(windows)]
fn dry_run_sync_dir_stats(src: &Path, dst: &Path) -> Result<DryRunSyncStats> {
    use std::collections::HashMap;
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

#[cfg(windows)]
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

#[cfg(windows)]
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

#[cfg(windows)]
fn windows_claude_exe_path(app_dir: &Path) -> Result<PathBuf> {
    [app_dir.join("Claude.exe"), app_dir.join("claude.exe")]
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| CoreError::Message(format!("未找到 Claude.exe: {}", app_dir.display())))
}

#[cfg(windows)]
fn write_windows_pristine_backup(
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

#[cfg(windows)]
fn ensure_windows_pristine_backup(
    app: &Path,
    resources: &Path,
    logger: &dyn LogSink,
) -> Result<PathBuf> {
    if let Some(existing) = windows_latest_pristine_backup(app)? {
        logger.info(format!("使用现有包外纯净备份: {}", existing.display()));
        return Ok(existing);
    }
    if windows_resources_look_patched(resources) {
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

#[cfg(windows)]
fn acquire_windowsapps_permission(path: &Path, logger: &dyn LogSink) -> Result<()> {
    let path_str = path.display().to_string();
    logger.info("正在获取 WindowsApps 目录写入权限。");
    // takeown: 获取目录所有权
    let mut takeown = Command::new("takeown");
    hide_command_window(&mut takeown);
    takeown.args(["/F", &path_str, "/R", "/A", "/D", "Y"]);
    let _ = run_command(takeown, logger, "获取目录所有权");
    // icacls: 授予管理员完全控制
    let mut icacls = Command::new("icacls");
    hide_command_window(&mut icacls);
    icacls.args([&path_str, "/grant", "Administrators:(OI)(CI)F", "/T", "/C"]);
    let _ = run_command(icacls, logger, "授予管理员写入权限");
    logger.info("WindowsApps 目录权限已更新。");
    Ok(())
}

#[cfg(windows)]
fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    if dst.exists() {
        remove_path(dst)?;
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

#[cfg(windows)]
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

#[cfg(windows)]
fn cleanup_windows_restore_artifacts(app_dir: &Path, logger: &dyn LogSink) -> Result<()> {
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

#[cfg(windows)]
fn try_cleanup_windows_restore_artifacts(app_dir: &Path, logger: &dyn LogSink) {
    if let Err(error) = cleanup_windows_restore_artifacts(app_dir, logger) {
        logger.warn(format!(
            "清理旧的 Windows 恢复临时文件失败，将保留残留以避免影响主流程: {error}"
        ));
    }
}

#[cfg(windows)]
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
                quit_claude(logger);
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

#[cfg(not(any(target_os = "macos", windows)))]
pub(crate) fn platform_install_patch(
    _resources: &Path,
    _req: &InstallRequest,
    _logger: &dyn LogSink,
) -> Result<()> {
    err("unsupported platform")
}

#[cfg(target_os = "macos")]
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

        // 步骤 2: 报告将恢复的备份
        let backup = backups.first().unwrap();
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
            for path in backups.iter().skip(1) {
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
    let Some(backup) = backups.first().cloned() else {
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
    for extra in backups.into_iter().skip(1) {
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

#[cfg(windows)]
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
            let script = windows_claude_probe_script();
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
                    let text = crate::logging::decode_command_output(&out.stdout);
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
                            logger.info(line.to_string());
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
            cmd.args(["/Query", "/TN", WATCHER_TASK])
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
    quit_claude(logger);
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
    let _ = unregister_update_watcher(logger);
    logger.info("Windows 恢复完成。");
    Ok(())
}

#[cfg(not(any(target_os = "macos", windows)))]
pub(crate) fn platform_restore_patch(_dry_run: bool, _logger: &dyn LogSink) -> Result<()> {
    err("unsupported platform")
}

#[cfg(windows)]
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

#[cfg(windows)]
fn restore_windows_backup_from_snapshot(
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

#[cfg(windows)]
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

#[cfg(windows)]
fn sync_windows_exe_asar_integrity(resources: &Path, logger: &dyn LogSink) -> Result<()> {
    let app = resources
        .parent()
        .ok_or_else(|| CoreError::Message("resources 路径无父目录。".to_string()))?;
    let exe = [app.join("Claude.exe"), app.join("claude.exe")]
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| CoreError::Message("未找到 Claude.exe。".to_string()))?;
    let header_hash = asar_header_hash(&resources.join("app.asar"))?;
    let marker = br#"resources\\app.asar","alg":"SHA256","value":""#;
    let mut data = fs::read(&exe)?;
    let pos = data
        .windows(marker.len())
        .position(|window| window == marker)
        .ok_or_else(|| CoreError::Message("未找到 Claude.exe app.asar 完整性标记。".to_string()))?;
    let hash_start = pos + marker.len();
    if hash_start + 64 > data.len() {
        return err("Claude.exe app.asar 完整性标记边界无效。");
    }
    data[hash_start..hash_start + 64].copy_from_slice(header_hash.as_bytes());
    fs::write(&exe, data)?;
    logger.info("已同步 Claude.exe app.asar 完整性哈希");
    Ok(())
}

#[cfg(windows)]
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

#[cfg(windows)]
fn unregister_update_watcher(logger: &dyn LogSink) -> Result<()> {
    let mut cmd = Command::new("schtasks");
    hide_command_window(&mut cmd);
    let removed = cmd
        .args(["/Delete", "/F", "/TN", WATCHER_TASK])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    if removed {
        logger.info("已移除旧的更新守护计划任务。");
    }
    Ok(())
}

#[cfg(all(test, windows))]
mod tests {
    use super::{
        cleanup_windows_restore_artifacts, restore_windows_backup_from_snapshot, sync_dir_exact,
        windows_claude_stop_script, windows_external_backup_prefix, windows_resources_look_patched,
        windowsapps_permission_targets,
    };
    use claude_zh_core::{now_millis, NoopLogger};
    use std::{fs, io::Write, path::Path, sync::Arc, thread, time::Duration};

    #[test]
    fn windowsapps_permissions_include_app_dir_for_exe_rewrite() {
        let resources = Path::new(
            r"C:\Program Files\WindowsApps\Claude_1.2.3.4_x64__pzs8sxrjxfjjc\app\resources",
        );

        let targets = windowsapps_permission_targets(resources);

        assert_eq!(
            targets,
            vec![
                resources.to_path_buf(),
                Path::new(r"C:\Program Files\WindowsApps\Claude_1.2.3.4_x64__pzs8sxrjxfjjc\app")
                    .to_path_buf()
            ]
        );
    }

    #[test]
    fn windows_external_backup_prefix_uses_package_dir_name() {
        let app = Path::new(r"C:\Program Files\WindowsApps\Claude_1.2.3.4_x64__pzs8sxrjxfjjc");

        let prefix = windows_external_backup_prefix(app).unwrap();

        assert_eq!(prefix, "Claude_1.2.3.4_x64__pzs8sxrjxfjjc");
    }

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

    #[test]
    fn windows_quit_script_kills_inaccessible_claude_processes() {
        let script = windows_claude_stop_script();

        assert!(script.contains("Get-CimInstance Win32_Process"));
        assert!(script.contains("$_.ExecutablePath"));
        assert!(script.contains("ParentProcessId"));
        assert!(script.contains("WindowsApps\\Claude_*"));
        assert!(script.contains("AnthropicClaude\\app-*\\*"));
        assert!(
            script.contains("Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue")
        );
    }
}
