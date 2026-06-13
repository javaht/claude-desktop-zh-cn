mod asar;
mod config;
mod error;
mod fs_utils;
mod frontend_locale;
mod frontend_patch;
mod hardcoded;
mod logging;
mod menu_patch;
mod online_dom;
mod record;
mod resources;
mod skills;
mod types;

pub use asar::*;
pub use config::*;
pub use error::*;
pub use fs_utils::*;
pub use frontend_locale::*;
pub use frontend_patch::*;
pub use hardcoded::*;
pub use logging::*;
pub use menu_patch::*;
pub use online_dom::*;
pub use record::*;
pub use resources::*;
pub use skills::*;
pub use types::*;

use std::{
    fs,
    path::Path,
};

pub const ASAR_PATCH_TARGET: &str = ".vite/build/index.js";

#[allow(clippy::type_complexity)]
pub fn install_into_resources(
    paths: InstallPaths<'_>,
    lang: &str,
    mode: &str,
    backup_modified: Option<&dyn Fn(&Path) -> Result<()>>,
    logger: &dyn LogSink,
) -> Result<()> {
    logger.info(format!(
        "开始安装资源: lang={lang}, mode={mode}, target={}",
        paths.target_resources.display()
    ));
    let pack = language_pack(paths.source_resources, lang)?;
    let i18n_dir = paths.target_resources.join("ion-dist").join("i18n");
    let assets_dir = paths
        .target_resources
        .join("ion-dist")
        .join("assets")
        .join("v1");
    let asar_path = paths.target_resources.join("app.asar");

    if let Some(backup) = backup_modified {
        logger.info("正在创建 Windows 资源备份");
        let mut backup_targets = vec![
            i18n_dir.join(format!("{lang}.json")),
            paths.target_resources.join(format!("{lang}.json")),
            i18n_dir.join("statsig").join(format!("{lang}.json")),
            asar_path.clone(),
        ];
        if let Ok(files) = js_files(&assets_dir) {
            backup_targets.extend(files);
        }
        logger.info(format!("Windows 资源备份候选: {} 个", backup_targets.len()));
        for path in backup_targets {
            backup(&path)?;
        }
        logger.info("Windows 资源备份完成。");
    }

    logger.info("正在创建语言资源目录。");
    fs::create_dir_all(&i18n_dir)?;
    fs::create_dir_all(i18n_dir.join("statsig"))?;
    merge_frontend_locale(&i18n_dir, &pack, lang, logger)?;
    install_desktop_locale(paths.target_resources, &pack, lang, logger)?;
    install_statsig_locale(&i18n_dir, &pack, lang, logger)?;
    patch_language_whitelist(&assets_dir, lang, logger)?;
    patch_hardcoded_frontend(&assets_dir, &pack.hardcoded, logger)?;
    patch_language_display_names(&assets_dir, logger)?;

    if asar_path.is_file() {
        logger.info(format!("开始处理 app.asar: {}", asar_path.display()));
        if mode == "safe" {
            patch_menu_labels(&asar_path, paths.mac_app_root, lang, true, logger)?;
            logger.info("Cowork 兼容模式：跳过在线页面和第三方模型名 app.asar 补丁。");
        } else {
            logger.info("正在构建在线页面 DOM 翻译映射。");
            let mapping = build_online_translation_map(&i18n_dir, &pack)?;
            patch_online_dom_translation(&asar_path, paths.mac_app_root, lang, mapping, logger)?;
            patch_menu_labels(&asar_path, paths.mac_app_root, lang, false, logger)?;
            logger.info("官方账号登录模式：跳过第三方模型名校验补丁。");
        }
    } else {
        logger.warn(format!(
            "未找到 app.asar，跳过结构性补丁: {}",
            asar_path.display()
        ));
    }
    logger.info("资源安装流程完成。");
    Ok(())
}

pub fn remove_language_files(resources: &Path) -> Result<()> {
    for lang in ["zh-CN", "zh-TW", "zh-HK"] {
        for path in [
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
        ] {
            let _ = remove_path(&path);
        }
    }
    Ok(())
}

pub fn unregister_language(resources: &Path, logger: &dyn LogSink) -> Result<()> {
    let assets = resources.join("ion-dist").join("assets").join("v1");
    let regex = language_list_regex()?;
    for file in js_files(&assets)? {
        let text = fs::read_to_string(&file)?;
        let replacement = format!("{BASE_LANGUAGE_LIST}]");
        let patched = regex.replacen(&text, 1, replacement).to_string();
        if patched != text {
            fs::write(file, patched)?;
        }
    }
    logger.info("已移除中文语言注册");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_install_request_accepts_valid_input() {
        let req = InstallRequest {
            language: "zh-CN".to_string(),
            mode: "safe".to_string(),
            launch_after: false,
            dry_run: false,
        };
        assert!(validate_install_request(&req).is_ok());
    }

    #[test]
    fn validate_install_request_rejects_invalid_language() {
        let req = InstallRequest {
            language: "fr-FR".to_string(),
            mode: "safe".to_string(),
            launch_after: false,
            dry_run: false,
        };
        let err = validate_install_request(&req).unwrap_err();
        assert!(err.to_string().contains("不支持的语言"));
    }

    #[test]
    fn validate_install_request_rejects_invalid_mode() {
        let req = InstallRequest {
            language: "zh-CN".to_string(),
            mode: "turbo".to_string(),
            launch_after: false,
            dry_run: false,
        };
        let err = validate_install_request(&req).unwrap_err();
        assert!(err.to_string().contains("不支持的模式"));
    }
}
