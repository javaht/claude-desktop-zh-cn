mod asar;
mod config;
mod error;
mod fs_utils;
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
pub use hardcoded::*;
pub use logging::*;
pub use menu_patch::*;
pub use online_dom::*;
pub use record::*;
pub use resources::*;
pub use skills::*;
pub use types::*;

use serde_json::{Map, Value};
use std::{
    ffi::OsStr,
    fs,
    path::Path,
};

pub const ASAR_PATCH_TARGET: &str = ".vite/build/index.js";

pub fn patch_language_display_names(assets_dir: &Path, logger: &dyn LogSink) -> Result<()> {
    let marker = "__claudeZhLabelPatch";
    let patch = r#";(()=>{const e=Intl.DisplayNames&&Intl.DisplayNames.prototype;if(!e||e.__claudeZhLabelPatch)return;const n=e.of;e.of=function(e){const t=String(e);return t==="zh-CN"?"简体中文":t==="zh-HK"?"繁体中文（中国香港）":t==="zh-TW"?"繁体中文（中国台湾）":n.call(this,e)},Object.defineProperty(e,"__claudeZhLabelPatch",{value:!0})})();"#;
    let mut count = 0;
    for path in js_files(assets_dir)? {
        let name = path.file_name().and_then(OsStr::to_str).unwrap_or_default();
        if !name.starts_with("index-") {
            continue;
        }
        let text = fs::read_to_string(&path)?;
        if text.contains(marker) {
            continue;
        }
        fs::write(&path, format!("{text}{patch}"))?;
        count += 1;
    }
    logger.info(format!("已补丁语言显示名: {count} 个文件"));
    Ok(())
}

pub fn merge_frontend_locale(
    i18n_dir: &Path,
    pack: &LanguagePack,
    lang: &str,
    logger: &dyn LogSink,
) -> Result<()> {
    logger.info(format!("开始合并前端语言包 {lang}。"));
    let en = read_json(&i18n_dir.join("en-US.json"))?;
    let zh = read_json(&pack.frontend)?;
    let en_obj = en
        .as_object()
        .ok_or_else(|| CoreError::Message("en-US.json 格式无效。".to_string()))?;
    let zh_obj = zh
        .as_object()
        .ok_or_else(|| CoreError::Message("frontend 中文资源格式无效。".to_string()))?;
    let mut merged = Map::new();
    let mut translated = 0usize;
    let mut fallback = 0usize;
    for (key, value) in en_obj {
        if let Some(target) = zh_obj.get(key) {
            if target != value {
                translated += 1;
            }
            merged.insert(key.clone(), target.clone());
        } else {
            fallback += 1;
            merged.insert(key.clone(), value.clone());
        }
    }
    write_json(
        &i18n_dir.join(format!("{lang}.json")),
        &Value::Object(merged),
    )?;
    logger.info(format!(
        "已合并前端语言包 {lang}: {translated} translated, {fallback} fallback"
    ));
    Ok(())
}

pub fn install_desktop_locale(
    resources_path: &Path,
    pack: &LanguagePack,
    lang: &str,
    logger: &dyn LogSink,
) -> Result<()> {
    logger.info(format!("开始写入桌面语言资源 {lang}。"));
    copy_file(&pack.desktop, &resources_path.join(format!("{lang}.json")))?;
    for folder in [
        format!("{lang}.lproj"),
        format!("{}.lproj", lang.replace('-', "_")),
    ] {
        let out_dir = resources_path.join(folder);
        fs::create_dir_all(&out_dir)?;
        copy_file(&pack.localizable, &out_dir.join("Localizable.strings"))?;
    }
    logger.info("桌面语言资源已写入。");
    Ok(())
}

pub fn install_statsig_locale(
    i18n_dir: &Path,
    pack: &LanguagePack,
    lang: &str,
    logger: &dyn LogSink,
) -> Result<()> {
    let statsig_dir = i18n_dir.join("statsig");
    if statsig_dir.is_dir() {
        logger.info(format!("开始写入 statsig 语言资源 {lang}。"));
        copy_file(&pack.statsig, &statsig_dir.join(format!("{lang}.json")))?;
        logger.info("statsig 语言资源已写入。");
    } else {
        logger.warn(format!(
            "未找到 statsig 目录，跳过: {}",
            statsig_dir.display()
        ));
    }
    Ok(())
}

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

pub fn patch_language_whitelist(assets_dir: &Path, lang: &str, logger: &dyn LogSink) -> Result<()> {
    logger.info(format!(
        "开始注册语言白名单: {lang}，扫描目录 {}",
        assets_dir.display()
    ));
    let regex = language_list_regex()?;
    let replacement = format!("{BASE_LANGUAGE_LIST},\"{lang}\"]");
    let mut changed = 0;
    let mut already = 0;
    for path in js_files(assets_dir)? {
        let text = fs::read_to_string(&path)?;
        if text.contains(&replacement) {
            already += 1;
            continue;
        }
        if regex.is_match(&text) {
            let patched = regex.replacen(&text, 1, replacement.as_str()).to_string();
            fs::write(&path, patched)?;
            logger.info(format!("已注册语言白名单: {}", path.display()));
            changed += 1;
        }
    }
    if changed + already == 0 {
        return err("未能注册中文语言，Claude 前端 bundle 格式可能已经变化。");
    }
    logger.info(format!(
        "语言白名单处理完成：新增 {changed} 个，已存在 {already} 个"
    ));
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
