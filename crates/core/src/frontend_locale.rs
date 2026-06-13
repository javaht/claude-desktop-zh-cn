use std::{fs, path::Path};

use crate::{copy_file, read_json, write_json, CoreError, LanguagePack, LogSink, LogSinkExt, Result};

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
    let mut merged = serde_json::Map::new();
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
        &serde_json::Value::Object(merged),
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
