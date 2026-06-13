use std::{ffi::OsStr, fs, path::Path};

use crate::{err, js_files, language_list_regex, resources::BASE_LANGUAGE_LIST, LogSink, Result};

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
