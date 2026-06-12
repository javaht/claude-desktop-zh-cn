use claude_zh_core::{sync_skills_impl, validate_install_request, CoreError, InstallRequest, LogSink, LogSinkExt, Result};
use std::path::Path;

use crate::{
    auto_update,
    elevation::run_elevated_cli,
    environment::{detect_claude, is_admin},
    os::{launch_claude, platform_install_patch, platform_restore_patch},
    paths::{cc_switch_skills_dir, skills_plugin_root},
};

pub fn install_patch(resources: &Path, req: &InstallRequest, logger: &dyn LogSink) -> Result<()> {
    validate_install_request(req)?;
    logger.info(format!(
        "安装请求: language={}, mode={}, launch_after={}, dry_run={}",
        req.language, req.mode, req.launch_after, req.dry_run
    ));
    logger.info(format!("使用随包资源: {}", resources.display()));
    if !is_admin() && !req.dry_run {
        logger.info("当前进程不是管理员权限，切换到系统授权安装。");
        let mut elevated_req = req.clone();
        elevated_req.launch_after = false;
        run_elevated_cli("install_patch", Some(elevated_req), None, None, Some(resources), logger)?;
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

pub fn restore_patch(dry_run: bool, logger: &dyn LogSink) -> Result<()> {
    logger.info(format!(
        "恢复请求: dry_run={}, 准备恢复官方 Claude.app 和英文语言配置。",
        dry_run
    ));
    if dry_run {
        logger.info("dry-run 模式：将检测恢复条件并打印恢复计划，不会修改任何文件。");
        return platform_restore_patch(true, logger);
    }
    if !is_admin() {
        logger.info("当前进程不是管理员权限，切换到系统授权恢复。");
        return run_elevated_cli(
            "restore_patch",
            None,
            Some(claude_zh_core::RestoreRequest { dry_run: false }),
            None,
            None,
            logger,
        );
    }
    logger.info("当前进程已有管理员权限，直接执行恢复。");
    platform_restore_patch(false, logger)
}

pub fn set_auto_updates(enabled: bool, logger: &dyn LogSink) -> Result<()> {
    // Windows: HKLM\Software\Policies\Claude 是机器级注册表路径，写入需管理员权限，所以非 admin 时走 elevation。
    // 读取永远不需要，所以 UI 状态显示不会受影响。macOS 不需要。
    #[cfg(windows)]
    {
        if !is_admin() {
            logger.info("当前进程不是管理员权限，切换到系统授权写入注册表策略。");
            return run_elevated_cli(
                "set_auto_updates",
                None,
                None,
                Some(enabled),
                None,
                logger,
            );
        }
    }
    auto_update::set_auto_updates(enabled, logger)
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
