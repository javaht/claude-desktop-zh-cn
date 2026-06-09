use claude_zh_core::{
    config_library_set_auto_updates, sync_skills_impl, CoreError, InstallRequest, LogSink,
    LogSinkExt, Result,
};
use std::path::Path;

use crate::{
    elevation::run_elevated_cli,
    environment::{detect_claude, is_admin},
    os::{launch_claude, platform_install_patch, platform_restore_patch},
    paths::{cc_switch_skills_dir, config_library_paths, skills_plugin_root},
    resources::resolve_resources,
};

pub fn install_patch(resources: &Path, req: &InstallRequest, logger: &dyn LogSink) -> Result<()> {
    logger.info(format!(
        "安装请求: language={}, mode={}, launch_after={}, dry_run={}",
        req.language, req.mode, req.launch_after, req.dry_run
    ));
    logger.info(format!("使用随包资源: {}", resources.display()));
    if !is_admin() && !req.dry_run {
        logger.info("当前进程不是管理员权限，切换到系统授权安装。");
        let mut elevated_req = req.clone();
        elevated_req.launch_after = false;
        run_elevated_cli("install_patch", Some(elevated_req), None, resources, logger)?;
        if req.launch_after {
            logger.info("提权安装已完成，正在从主进程启动 Claude Desktop。");
            if let Some((app, _, _)) = detect_claude() {
                launch_claude(&app, logger);
            } else {
                logger.warn("安装已完成，但未检测到 Claude Desktop 启动路径。");
            }
        }
        return Ok(());
    }
    if req.dry_run {
        logger.info("dry-run 模式：将验证补丁流程，不会替换真实安装。");
    } else {
        logger.info("当前进程已有管理员权限，直接执行安装。");
    }
    platform_install_patch(resources, req, logger)
}

pub fn restore_patch(logger: &dyn LogSink) -> Result<()> {
    logger.info("恢复请求: 准备恢复官方 Claude.app 和英文语言配置。");
    if !is_admin() {
        let resources = resolve_resources(None)?;
        logger.info("当前进程不是管理员权限，切换到系统授权恢复。");
        return run_elevated_cli("restore_patch", None, None, &resources, logger);
    }
    logger.info("当前进程已有管理员权限，直接执行恢复。");
    platform_restore_patch(logger)
}

pub fn set_auto_updates(enabled: bool, logger: &dyn LogSink) -> Result<()> {
    logger.info(format!(
        "自动更新请求: {}",
        if enabled { "开启" } else { "停止" }
    ));
    let paths = config_library_paths();
    if paths.is_empty() {
        logger.warn("未找到 configLibrary 路径，无法写入自动更新设置。");
        return Ok(());
    }
    for path in paths {
        config_library_set_auto_updates(&path, enabled, logger)?;
    }
    logger.info("自动更新设置已写入。");
    Ok(())
}

pub fn sync_cc_switch_skills(logger: &dyn LogSink) -> Result<()> {
    logger.info("准备同步 CC Switch skills。");
    let plugin = skills_plugin_root()
        .ok_or_else(|| CoreError::Message("未找到 Claude Desktop skills plugin。".to_string()))?;
    let skills = cc_switch_skills_dir()
        .ok_or_else(|| CoreError::Message("未找到 CC Switch skills 目录。".to_string()))?;
    logger.info(format!("Claude skills plugin: {}", plugin.display()));
    logger.info(format!("CC Switch skills: {}", skills.display()));
    sync_skills_impl(&plugin, &skills, false, logger)
}

pub fn unsync_cc_switch_skills(logger: &dyn LogSink) -> Result<()> {
    logger.info("准备删除 CC Switch skills 同步。");
    let plugin = skills_plugin_root()
        .ok_or_else(|| CoreError::Message("未找到 Claude Desktop skills plugin。".to_string()))?;
    let skills = cc_switch_skills_dir()
        .ok_or_else(|| CoreError::Message("未找到 CC Switch skills 目录。".to_string()))?;
    logger.info(format!("Claude skills plugin: {}", plugin.display()));
    logger.info(format!("CC Switch skills: {}", skills.display()));
    sync_skills_impl(&plugin, &skills, true, logger)
}
