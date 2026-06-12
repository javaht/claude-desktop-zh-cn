mod config;
mod error;
mod fs_utils;
mod logging;
mod resources;
mod skills;
mod types;

pub use config::*;
pub use error::*;
pub use fs_utils::*;
pub use logging::*;
pub use resources::*;
pub use skills::*;
pub use types::*;

use aho_corasick::AhoCorasick;
use chrono::Local;
use regex::Regex;
use serde_json::{json, Map, Value};
use std::{
    collections::BTreeMap,
    ffi::OsStr,
    fs,
    ops::Range,
    path::{Path, PathBuf},
};

pub const ASAR_PATCH_TARGET: &str = ".vite/build/index.js";
pub const ONLINE_MARKER: &str = "__claudeZhOnlineLocaleMain";
const ASAR_BLOCK_SIZE: usize = 4 * 1024 * 1024;

pub fn patch_hardcoded_frontend(
    assets_dir: &Path,
    replacements_path: &Path,
    logger: &dyn LogSink,
) -> Result<()> {
    let replacements = hardcoded_replacements(replacements_path)?;
    let replacement_matcher = AhoCorasick::new(replacements.iter().map(|(source, _)| source))
        .map_err(|error| CoreError::Message(format!("硬编码匹配器构建失败: {error}")))?;
    let files = js_files(assets_dir)?;
    logger.info(format!(
        "开始汉化硬编码前端文本：{} 个文件，{} 条候选",
        files.len(),
        replacements.len()
    ));
    let mut patched_files = 0usize;
    let mut patched_strings = 0usize;
    for (index, path) in files.iter().enumerate() {
        if index > 0 && index % 40 == 0 {
            logger.info(format!("硬编码文本扫描进度：{}/{}", index, files.len()));
        }
        let original = fs::read_to_string(path)?;
        let candidates: Vec<_> = hardcoded_candidate_indexes(&replacement_matcher, &original)
            .into_iter()
            .map(|index| &replacements[index])
            .collect();
        if candidates.is_empty() {
            continue;
        }
        let mut patched = original.clone();
        let mut count = 0usize;
        for (source, target) in candidates {
            let (next, occurrences) = replace_frontend_text(&patched, source, target)?;
            patched = next;
            count += occurrences;
        }
        if patched != original {
            fs::write(path, patched)?;
            patched_files += 1;
            patched_strings += count;
        }
    }
    logger.info(format!(
        "已汉化前端硬编码文本: {patched_strings} 处，{patched_files} 个文件"
    ));
    Ok(())
}

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

fn replace_frontend_text(text: &str, source: &str, target: &str) -> Result<(String, usize)> {
    if is_structural_js_literal(source) || !text.contains(source) {
        return Ok((text.to_string(), 0));
    }
    if !is_plain_ui_text(source) {
        let count = text.matches(source).count();
        return Ok((text.replace(source, target), count));
    }
    let mut patched = text.to_string();
    let mut count = 0;
    for quote in ['"', '\'', '`'] {
        let needle = format!("{quote}{source}{quote}");
        let replacement = format!("{quote}{target}{quote}");
        let local = patched.matches(&needle).count();
        if local > 0 {
            patched = patched.replace(&needle, &replacement);
            count += local;
        }
    }
    Ok((patched, count))
}

fn hardcoded_candidate_indexes(matcher: &AhoCorasick, text: &str) -> Vec<usize> {
    let mut candidate_indexes: Vec<_> = matcher
        .find_overlapping_iter(text)
        .map(|matched| matched.pattern().as_usize())
        .collect();
    candidate_indexes.sort_unstable();
    candidate_indexes.dedup();
    candidate_indexes
}

pub fn hardcoded_replacements(path: &Path) -> Result<Vec<(String, String)>> {
    let data = read_json(path)?;
    let array = data
        .as_array()
        .ok_or_else(|| CoreError::Message(format!("硬编码替换资源格式无效: {}", path.display())))?;
    let mut out = Vec::new();
    for item in array {
        let pair = item.as_array().ok_or_else(|| {
            CoreError::Message(format!("硬编码替换条目格式无效: {}", path.display()))
        })?;
        if pair.len() != 2 {
            return err(format!("硬编码替换条目长度无效: {}", path.display()));
        }
        let source = pair[0].as_str().unwrap_or_default();
        if is_structural_js_literal(source) {
            continue;
        }
        out.push((
            source.to_string(),
            pair[1].as_str().unwrap_or_default().to_string(),
        ));
    }
    out.sort_by_key(|b| std::cmp::Reverse(b.0.len()));
    Ok(out)
}

pub fn is_structural_js_literal(source: &str) -> bool {
    matches!(
        source,
        "hour"
            | "hours"
            | "minute"
            | "minutes"
            | "second"
            | "seconds"
            | "day"
            | "days"
            | "week"
            | "weeks"
            | "month"
            | "months"
            | "year"
            | "years"
            | r#""Search""#
    )
}

fn is_plain_ui_text(source: &str) -> bool {
    !source.contains('\n')
        && !["\"", "\\", "=", ";", "=>"]
            .iter()
            .any(|m| source.contains(m))
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

fn align4(value: usize) -> Option<usize> {
    let remainder = (4 - (value % 4)) % 4;
    value.checked_add(remainder)
}

#[derive(Clone, Debug)]
pub struct AsarArchive {
    path: PathBuf,
    data: Vec<u8>,
    header_size: usize,
    header: Value,
}

impl AsarArchive {
    pub fn open(path: &Path) -> Result<Self> {
        let data = fs::read(path)?;
        Self::from_data(path.to_path_buf(), data)
    }

    pub fn from_data(path: PathBuf, data: Vec<u8>) -> Result<Self> {
        if data.len() < 16 {
            return err(format!("Unsupported app.asar header: {}", path.display()));
        }
        let size_pickle = u32::from_le_bytes(data[0..4].try_into().unwrap()) as usize;
        let header_size = u32::from_le_bytes(data[4..8].try_into().unwrap()) as usize;
        if size_pickle != 4 || header_size == 0 || data.len() < 8 + header_size {
            return err(format!(
                "Unsupported app.asar size pickle: {}",
                path.display()
            ));
        }
        let header_pickle = &data[8..8 + header_size];
        let payload_size = u32::from_le_bytes(header_pickle[0..4].try_into().unwrap()) as usize;
        let raw_string_size = i32::from_le_bytes(header_pickle[4..8].try_into().unwrap());
        if raw_string_size < 0 {
            return err(format!(
                "app.asar header string_size 为负数: {raw_string_size}"
            ));
        }
        // 安全：raw_string_size 已在上方检查 >= 0，非负 i32 合法转 usize
        let string_size = raw_string_size as usize;
        let expected_payload_size = align4(
            4usize
                .checked_add(string_size)
                .ok_or_else(|| CoreError::Message("app.asar payload_size 溢出".to_string()))?,
        )
        .ok_or_else(|| CoreError::Message("app.asar align4 溢出".to_string()))?;
        let expected_pickle_size = 4usize
            .checked_add(expected_payload_size)
            .ok_or_else(|| CoreError::Message("app.asar pickle_size 溢出".to_string()))?;
        if payload_size != expected_payload_size || header_size != expected_pickle_size {
            return err(format!(
                "Unsupported app.asar header pickle: {}",
                path.display()
            ));
        }
        let header_string = std::str::from_utf8(&header_pickle[8..8 + string_size])
            .map_err(|e| CoreError::Message(e.to_string()))?;
        let header: Value = serde_json::from_str(header_string)?;
        Ok(Self {
            path,
            data,
            header_size,
            header,
        })
    }

    pub fn header_string(&self) -> Result<String> {
        Ok(serde_json::to_string(&self.header)?)
    }

    fn get_entry_mut<'a>(
        node: &'a mut Value,
        file_path: &str,
    ) -> Result<&'a mut Map<String, Value>> {
        let mut current = node;
        for part in file_path.split('/') {
            current = current
                .get_mut("files")
                .and_then(Value::as_object_mut)
                .and_then(|files| files.get_mut(part))
                .ok_or_else(|| CoreError::Message(format!("app.asar 中找不到 {file_path}")))?;
        }
        current
            .as_object_mut()
            .ok_or_else(|| CoreError::Message(format!("app.asar entry 格式无效: {file_path}")))
    }

    fn get_entry<'a>(node: &'a Value, file_path: &str) -> Result<&'a Map<String, Value>> {
        let mut current = node;
        for part in file_path.split('/') {
            current = current
                .get("files")
                .and_then(Value::as_object)
                .and_then(|files| files.get(part))
                .ok_or_else(|| CoreError::Message(format!("app.asar 中找不到 {file_path}")))?;
        }
        current
            .as_object()
            .ok_or_else(|| CoreError::Message(format!("app.asar entry 格式无效: {file_path}")))
    }

    fn entry_bounds(&self, file_path: &str) -> Result<(usize, usize, usize)> {
        let entry = Self::get_entry(&self.header, file_path)?;
        let offset = entry_value_usize(entry, "offset")?;
        let size = entry_value_usize(entry, "size")?;
        let start = 8usize
            .checked_add(self.header_size)
            .and_then(|base| base.checked_add(offset))
            .ok_or_else(|| {
                CoreError::Message(format!("app.asar offset 溢出: {file_path}"))
            })?;
        let end = start
            .checked_add(size)
            .ok_or_else(|| CoreError::Message(format!("app.asar size 溢出: {file_path}")))?;
        if end > self.data.len() {
            return err(format!("app.asar bounds 无效: {file_path}"));
        }
        Ok((offset, start, end))
    }

    pub fn read_text(&self, file_path: &str) -> Result<String> {
        let (_, start, end) = self.entry_bounds(file_path)?;
        String::from_utf8(self.data[start..end].to_vec())
            .map_err(|e| CoreError::Message(e.to_string()))
    }

    pub fn replace_file(&mut self, file_path: &str, patched: &[u8]) -> Result<bool> {
        let (target_offset, start, end) = self.entry_bounds(file_path)?;
        if self.data[start..end] == *patched {
            return Ok(false);
        }
        let old_size = end - start;
        self.data.splice(start..end, patched.iter().copied());
        let delta = patched.len() as isize - old_size as isize;
        {
            let entry = Self::get_entry_mut(&mut self.header, file_path)?;
            entry.insert("size".to_string(), json!(patched.len()));
            entry.insert("integrity".to_string(), file_integrity(patched));
        }
        if delta != 0 {
            shift_offsets(&mut self.header, target_offset, delta)?;
        }
        Ok(true)
    }

    pub fn save(&self) -> Result<String> {
        let header_string = serde_json::to_string(&self.header)?;
        let header = encode_asar_header_dynamic(&header_string)?;
        let body = &self.data[8 + self.header_size..];
        let mut out = header;
        out.extend_from_slice(body);
        fs::write(&self.path, out)?;
        Ok(header_string)
    }
}

fn entry_value_usize(entry: &Map<String, Value>, key: &str) -> Result<usize> {
    let value = entry
        .get(key)
        .ok_or_else(|| CoreError::Message(format!("asar entry 缺少 {key}")))?;
    if let Some(num) = value.as_u64() {
        Ok(num as usize)
    } else if let Some(text) = value.as_str() {
        text.parse::<usize>()
            .map_err(|e| CoreError::Message(format!("asar entry {key} 无效: {e}")))
    } else {
        err(format!("asar entry {key} 类型无效"))
    }
}

fn set_entry_offset(entry: &mut Map<String, Value>, offset: usize) {
    let as_string = entry.get("offset").is_some_and(Value::is_string);
    entry.insert(
        "offset".to_string(),
        if as_string {
            Value::String(offset.to_string())
        } else {
            json!(offset)
        },
    );
}

fn shift_offsets(node: &mut Value, target_offset: usize, delta: isize) -> Result<()> {
    let Some(files) = node.get_mut("files").and_then(Value::as_object_mut) else {
        return Ok(());
    };
    for child in files.values_mut() {
        if child.get("files").is_some() {
            shift_offsets(child, target_offset, delta)?;
        } else if let Some(entry) = child.as_object_mut() {
            if entry.contains_key("offset") && entry.contains_key("size") {
                let offset = entry_value_usize(entry, "offset")?;
                if offset > target_offset {
                    let new_offset = (offset as i64)
                        .checked_add(delta as i64)
                        .ok_or_else(|| {
                            CoreError::Message("app.asar offset 调整溢出".to_string())
                        })?;
                    if new_offset < 0 {
                        return err("app.asar offset 调整后为负数".to_string());
                    }
                    set_entry_offset(entry, new_offset as usize);
                }
            }
        }
    }
    Ok(())
}

fn file_integrity(data: &[u8]) -> Value {
    let mut blocks: Vec<Value> = data
        .chunks(ASAR_BLOCK_SIZE)
        .map(|chunk| Value::String(sha256_hex(chunk)))
        .collect();
    if blocks.is_empty() {
        blocks.push(Value::String(sha256_hex(data)));
    }
    json!({
        "algorithm": "SHA256",
        "hash": sha256_hex(data),
        "blockSize": ASAR_BLOCK_SIZE,
        "blocks": blocks
    })
}

pub fn encode_asar_header_dynamic(header_string: &str) -> Result<Vec<u8>> {
    let header_bytes = header_string.as_bytes();
    let payload_size = align4(4 + header_bytes.len()).expect("header payload 超出限制");
    let pickle_size = 4 + payload_size;
    let mut out = Vec::with_capacity(8 + pickle_size);
    out.extend_from_slice(&(4u32).to_le_bytes());
    out.extend_from_slice(
        &u32::try_from(pickle_size)
            .map_err(|_| CoreError::Message(format!("asar pickle_size {} 超过 u32::MAX", pickle_size)))?
            .to_le_bytes(),
    );
    out.extend_from_slice(
        &u32::try_from(payload_size)
            .map_err(|_| CoreError::Message(format!("asar payload_size {} 超过 u32::MAX", payload_size)))?
            .to_le_bytes(),
    );
    out.extend_from_slice(
        &i32::try_from(header_bytes.len())
            .map_err(|_| CoreError::Message(format!("asar header 长度 {} 超过 i32::MAX", header_bytes.len())))?
            .to_le_bytes(),
    );
    out.extend_from_slice(header_bytes);
    out.resize(8 + pickle_size, 0);
    Ok(out)
}

pub fn update_macos_asar_integrity(app_path: &Path, header_string: &str) -> Result<()> {
    let info_plist = app_path.join("Contents/Info.plist");
    if !info_plist.is_file() {
        return Ok(());
    }
    let mut value = plist::Value::from_file(&info_plist)?;
    if let Some(dict) = value.as_dictionary_mut() {
        if let Some(integrity) = dict
            .get_mut("ElectronAsarIntegrity")
            .and_then(plist::Value::as_dictionary_mut)
        {
            if let Some(app_asar) = integrity
                .get_mut("Resources/app.asar")
                .and_then(plist::Value::as_dictionary_mut)
            {
                app_asar.insert(
                    "hash".to_string(),
                    plist::Value::String(sha256_hex(header_string.as_bytes())),
                );
            }
        }
    }
    value.to_file_xml(info_plist)?;
    Ok(())
}

pub fn patch_asar_text(
    asar_path: &Path,
    app_root: Option<&Path>,
    patcher: impl FnOnce(String) -> Result<Option<String>>,
) -> Result<bool> {
    let mut asar = AsarArchive::open(asar_path)?;
    let text = asar.read_text(ASAR_PATCH_TARGET)?;
    let Some(patched) = patcher(text)? else {
        return Ok(false);
    };
    if !asar.replace_file(ASAR_PATCH_TARGET, patched.as_bytes())? {
        return Ok(false);
    }
    let header_string = asar.save()?;
    if let Some(app_root) = app_root {
        update_macos_asar_integrity(app_root, &header_string)?;
    }
    Ok(true)
}

pub fn build_online_translation_map(
    installed_i18n: &Path,
    pack: &LanguagePack,
) -> Result<BTreeMap<String, String>> {
    let en = read_json(&installed_i18n.join("en-US.json"))?;
    let zh = read_json(&pack.frontend)?;
    let mut map = BTreeMap::new();
    if let (Some(en_obj), Some(zh_obj)) = (en.as_object(), zh.as_object()) {
        for (key, source) in en_obj {
            if let (Some(source), Some(target)) =
                (source.as_str(), zh_obj.get(key).and_then(Value::as_str))
            {
                if is_online_dom_translation_entry(source, target) {
                    map.insert(source.to_string(), target.to_string());
                }
            }
        }
    }
    for (source, target) in hardcoded_replacements(&pack.hardcoded)? {
        if is_online_dom_translation_entry(&source, &target) {
            map.insert(source, target);
        }
    }
    Ok(map)
}

fn is_online_dom_translation_entry(source: &str, target: &str) -> bool {
    !source.is_empty()
        && !target.is_empty()
        && source != target
        && source.len() <= 240
        && !["<", "{", "\n", "http://", "https://"]
            .iter()
            .any(|fragment| source.contains(fragment) || target.contains(fragment))
}

pub fn build_online_dom_translation_script(
    lang: &str,
    mapping: &BTreeMap<String, String>,
) -> Result<String> {
    let mapping_json = serde_json::to_string(mapping)?;
    let lang_json = serde_json::to_string(lang)?;
    let (selected_text, delete_selected_text) = if matches!(lang, "zh-TW" | "zh-HK") {
        ("已選擇 $1 項", "刪除 $1 個所選項目")
    } else {
        ("已选择 $1 项", "删除 $1 个所选项目")
    };
    let selected_json = serde_json::to_string(selected_text)?;
    let delete_selected_json = serde_json::to_string(delete_selected_text)?;
    Ok(format!(
        r#"(()=>{{try{{const L={lang_json},M={mapping_json};localStorage.setItem("spa:locale",L);document.documentElement&&document.documentElement.setAttribute("lang",L);const N=s=>(s||"").replace(/\s+/g," ").trim();const G=[[/^Morning, (.+)$/,"早上好，$1"],[/^Good morning, (.+)$/,"早上好，$1"],[/^Afternoon, (.+)$/,"下午好，$1"],[/^Good afternoon, (.+)$/,"下午好，$1"],[/^Evening, (.+)$/,"晚上好，$1"],[/^Good evening, (.+)$/,"晚上好，$1"],[/^It's late-night (.+)$/,"夜深了，$1"],[/^Good night, (.+)$/,"晚安，$1"],[/^Delete (\d+) chat$/,"删除 $1 个聊天"],[/^Delete (\d+) chats$/,"删除 $1 个聊天"],[/^Move (\d+) chat to a project$/,"将 $1 个聊天移至项目"],[/^Move (\d+) chats to a project$/,"将 $1 个聊天移至项目"],[/^Connection needs (\d+) field$/,"连接还需要填写 $1 个字段"],[/^Connection needs (\d+) fields$/,"连接还需要填写 $1 个字段"],[/^needs (\d+) field$/,"还需要填写 $1 个字段"],[/^needs (\d+) fields$/,"还需要填写 $1 个字段"],[/^Are you sure you want to delete (\d+) chat\? This cannot be undone\.$/,"你确定要删除 $1 个聊天吗？此操作无法撤消。"],[/^Are you sure you want to delete (\d+) chats\? This cannot be undone\.$/,"你确定要删除 $1 个聊天吗？此操作无法撤消。"],[/^Are you sure you want to permanently delete this chat\? This cannot be undone\.$/,"你确定要永久删除此聊天吗？此操作无法撤消。"],[/^Are you sure you want to permanently delete these chats\? This cannot be undone\.$/,"你确定要永久删除这些聊天吗？此操作无法撤消。"],[/^(\d+) selected$/,{selected_json}],[/^Delete (\d+) selected item$/,{delete_selected_json}],[/^Delete (\d+) selected items$/,{delete_selected_json}],[/^Mon$/,"周一"],[/^Tue$/,"周二"],[/^Wed$/,"周三"],[/^Thu$/,"周四"],[/^Fri$/,"周五"],[/^Sat$/,"周六"],[/^Sun$/,"周日"]];const R=s=>{{const n=N(s);if(M[n])return M[n];for(const [r,t]of G){{const m=n.match(r);if(m)return t.replace("$1",m[1])}}}};const X=new Set(["SCRIPT","STYLE","NOSCRIPT"]);function T(){{try{{const b=document.body||document.documentElement;if(!b)return;const w=document.createTreeWalker(b,NodeFilter.SHOW_TEXT,{{acceptNode(n){{const p=n.parentElement;if(!p||X.has(p.tagName)||p.closest("[contenteditable]")||!R(n.nodeValue))return NodeFilter.FILTER_REJECT;return NodeFilter.FILTER_ACCEPT}}}});let n;while(n=w.nextNode()){{const v=R(n.nodeValue);if(v)n.nodeValue=v}}document.querySelectorAll("[aria-label],[title],[placeholder],input,textarea").forEach(e=>{{["aria-label","title","placeholder","value"].forEach(a=>{{try{{if(a==="value"&&!(e.matches("input[type=button],input[type=submit]")))return;let v=e.getAttribute?e.getAttribute(a):void 0;if(v==null&&a in e)v=e[a];const t=R(v);if(t){{if(e.setAttribute)e.setAttribute(a,t);try{{if(a in e)e[a]=t}}catch{{}}}}}}catch{{}}}})}});document.querySelectorAll("a").forEach(e=>{{try{{const r=e.getBoundingClientRect(),txt=N(e.textContent);if(txt==="Claude"&&r.left<100&&r.top<100)e.style.visibility="hidden"}}catch{{}}}})}}catch{{}}}}T();new MutationObserver(()=>{{clearTimeout(window.__claudeZhDomTimer);window.__claudeZhDomTimer=setTimeout(T,30)}}).observe(document.documentElement,{{subtree:true,childList:true,characterData:true,attributes:true}})}}catch(e){{}}}})()"#
    ))
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DomReadyHook {
    full_range: Range<usize>,
    receiver: String,
    body: String,
}

fn dom_ready_hook_regex() -> Result<Regex> {
    Regex::new(
        r#"(?P<receiver>[A-Za-z_$][A-Za-z0-9_$]*(?:\.webContents)?)\.on\("dom-ready",\(\)=>\{(?P<body>[^{}]*)\}\);"#,
    )
    .map_err(Into::into)
}

fn dom_ready_hook_from_match(caps: &regex::Captures<'_>) -> DomReadyHook {
    let full = caps.get(0).unwrap();
    DomReadyHook {
        full_range: full.start()..full.end(),
        receiver: caps.name("receiver").unwrap().as_str().to_string(),
        body: caps.name("body").unwrap().as_str().to_string(),
    }
}

fn text_before(text: &str, end: usize, max_chars: usize) -> &str {
    let start = text[..end]
        .char_indices()
        .rev()
        .nth(max_chars)
        .map(|(index, _)| index)
        .unwrap_or(0);
    &text[start..end]
}

fn find_online_dom_ready_hook(text: &str) -> Result<Option<DomReadyHook>> {
    let hook = dom_ready_hook_regex()?;
    let hooks: Vec<DomReadyHook> = hook
        .captures_iter(text)
        .map(|caps| dom_ready_hook_from_match(&caps))
        .collect();

    let main_marker_hooks: Vec<DomReadyHook> = hooks
        .iter()
        .filter(|hook| hook.body.contains("main_view_dom_ready"))
        .cloned()
        .collect();
    if main_marker_hooks.len() > 1 {
        return err("找到多个 main_view_dom_ready dom-ready 注入点，无法安全补丁。");
    }
    if let Some(hook) = main_marker_hooks.into_iter().next() {
        return Ok(Some(hook));
    }

    let main_view_hooks: Vec<DomReadyHook> = hooks
        .iter()
        .filter(|hook| {
            text_before(text, hook.full_range.start, 2500).contains(".vite/build/mainView.js")
        })
        .cloned()
        .collect();
    if main_view_hooks.len() > 1 {
        return err("找到多个 main view dom-ready 注入点，无法安全补丁。");
    }
    if let Some(hook) = main_view_hooks.into_iter().next() {
        return Ok(Some(hook));
    }

    Ok(hooks.into_iter().next())
}

pub fn patch_online_dom_translation(
    asar_path: &Path,
    app_root: Option<&Path>,
    lang: &str,
    mapping: BTreeMap<String, String>,
    logger: &dyn LogSink,
) -> Result<()> {
    let marker = ONLINE_MARKER.to_string();
    let script = build_online_dom_translation_script(lang, &mapping)?;
    let changed = patch_asar_text(asar_path, app_root, |text| {
        let stripped = strip_existing_online_patch(&text, &marker)?;
        if let Some(hook) = find_online_dom_ready_hook(&stripped)? {
            let injection = format!(
                r#"{}.on("dom-ready",()=>{{{};{}.executeJavaScript({}).catch(()=>{{}})}});/*{marker}*/"#,
                &hook.receiver,
                &hook.body,
                &hook.receiver,
                serde_json::to_string(&script)?
            );
            let mut patched = stripped;
            patched.replace_range(hook.full_range, &injection);
            Ok(Some(patched))
        } else {
            Ok(None)
        }
    })?;
    if changed {
        logger.info(format!("已注入在线页面 DOM 翻译: {} 条文本", mapping.len()));
    } else {
        logger.warn("未找到在线页面 DOM 翻译注入点，已跳过 app.asar 在线页面补丁。");
    }
    Ok(())
}

fn strip_existing_online_patch(text: &str, marker: &str) -> Result<String> {
    if !text.contains(marker) {
        return Ok(text.to_string());
    }
    let pattern = Regex::new(&format!(
        r#"(?P<receiver>[A-Za-z_$][A-Za-z0-9_$]*(?:\.webContents)?)\.on\("dom-ready",\(\)=>\{{(?P<body>.*?);(?P<exec_receiver>[A-Za-z_$][A-Za-z0-9_$]*(?:\.webContents)?)\.executeJavaScript\("(?:\\.|[^"])*"\)\.catch\(\(\)=>\{{\}}\)\}}\);/\*{}\*/"#,
        regex::escape(marker)
    ))?;
    Ok(pattern
        .replace_all(text, |caps: &regex::Captures<'_>| {
            if caps.name("receiver").map(|m| m.as_str())
                != caps.name("exec_receiver").map(|m| m.as_str())
            {
                return caps.get(0).unwrap().as_str().to_string();
            }
            format!(
                r#"{}.on("dom-ready",()=>{{{}}});"#,
                &caps["receiver"], &caps["body"]
            )
        })
        .to_string())
}

fn menu_replacements(lang: &str) -> BTreeMap<&'static str, &'static str> {
    match lang {
        "zh-TW" | "zh-HK" => BTreeMap::from([
            ("File", "檔案"),
            ("Edit", "編輯"),
            ("View", "檢視"),
            ("Developer", "開發者"),
            ("Help", "說明"),
            ("Extensions", "擴充功能"),
            ("Open Developer Config File...", "開啟開發者設定檔..."),
            ("Configure Third-Party Inference...", "設定第三方推理..."),
            ("Open App Config File...", "開啟應用程式設定檔..."),
            ("Reload MCP Configuration", "重新載入 MCP 設定"),
            ("Open MCP Log File", "開啟 MCP 記錄檔"),
            ("Show All Dev Tools", "顯示所有開發者工具"),
            ("Show Dev Tools", "顯示開發者工具"),
        ]),
        _ => BTreeMap::from([
            ("File", "文件"),
            ("Edit", "编辑"),
            ("View", "查看"),
            ("Developer", "开发者"),
            ("Help", "帮助"),
            ("Extensions", "扩展"),
            ("Open Developer Config File...", "打开开发者配置文件..."),
            ("Configure Third-Party Inference...", "配置第三方推理..."),
            ("Open App Config File...", "打开应用配置文件..."),
            ("Reload MCP Configuration", "重新加载 MCP 配置"),
            ("Open MCP Log File", "打开 MCP 日志文件"),
            ("Show All Dev Tools", "显示所有开发者工具"),
            ("Show Dev Tools", "显示开发者工具"),
        ]),
    }
}

pub fn patch_menu_labels(
    asar_path: &Path,
    app_root: Option<&Path>,
    lang: &str,
    length_preserving: bool,
    logger: &dyn LogSink,
) -> Result<()> {
    let replacements = menu_replacements(lang);
    let changed = patch_asar_text(asar_path, app_root, |text| {
        let mut patched = text.clone();
        let mut count = 0usize;
        for (source, target) in replacements {
            for key in ["label", "defaultMessage"] {
                for quote in ['"', '\'', '`'] {
                    let needle = format!("{key}:{quote}{source}{quote}");
                    let replacement = format!("{key}:{quote}{target}{quote}");
                    let local = patched.matches(&needle).count();
                    if local == 0 {
                        continue;
                    }
                    let final_replacement = if length_preserving {
                        let delta = needle.len() as isize - replacement.len() as isize;
                        if delta >= 0 {
                            format!("{}{}", replacement, " ".repeat(delta as usize))
                        } else {
                            continue;
                        }
                    } else {
                        replacement
                    };
                    patched = patched.replace(&needle, &final_replacement);
                    count += local;
                }
            }
        }
        if count > 0 {
            Ok(Some(patched))
        } else {
            Ok(None)
        }
    })?;
    if changed {
        logger.info("已汉化主进程菜单文本");
    } else {
        logger.warn("未找到主进程菜单文本补丁点，已跳过。");
    }
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

pub fn asar_header_hash(path: &Path) -> Result<String> {
    let asar = AsarArchive::open(path)?;
    Ok(sha256_hex(asar.header_string()?.as_bytes()))
}

pub fn patched_version_record(
    app: &Path,
    mode: &str,
    language: &str,
    gui_exe: Option<&Path>,
) -> Value {
    let version = app
        .file_name()
        .and_then(OsStr::to_str)
        .and_then(|name| name.strip_prefix("app-"))
        .unwrap_or("unknown");
    json!({
        "version": version,
        "installPath": app,
        "patchTime": Local::now().to_rfc3339(),
        "patchMode": mode,
        "language": language,
        "guiExe": gui_exe.map(|path| path.display().to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn structural_search_literal_is_skipped() {
        assert!(is_structural_js_literal(r#""Search""#));
        let (text, count) = replace_frontend_text(r#"x="Search";"#, r#""Search""#, "搜索").unwrap();
        assert_eq!(text, r#"x="Search";"#);
        assert_eq!(count, 0);
    }

    #[test]
    fn hardcoded_candidates_include_overlapping_literals() {
        let matcher = AhoCorasick::new(["New", "New Chat", "Chat"]).unwrap();
        assert_eq!(
            hardcoded_candidate_indexes(&matcher, "Start New Chat"),
            vec![0, 1, 2]
        );
    }

    #[test]
    fn asar_header_round_trip_encodes_parseable_header() {
        let header = r#"{"files":{"a.txt":{"offset":"0","size":3}}}"#;
        let encoded = encode_asar_header_dynamic(header).unwrap();
        assert_eq!(&encoded[0..4], &(4u32).to_le_bytes());
        let header_size = u32::from_le_bytes(encoded[4..8].try_into().unwrap()) as usize;
        assert_eq!(encoded.len(), 8 + header_size);
    }

    #[test]
    fn online_dom_ready_hook_prefers_main_view_marker() {
        let text = r#"a.webContents.on("dom-ready",()=>{first()});s.webContents.on("dom-ready",()=>{L3("main_view_dom_ready"),pEA()});"#;

        let hook = find_online_dom_ready_hook(text).unwrap().unwrap();

        assert_eq!(hook.receiver, "s.webContents");
        assert_eq!(hook.body, r#"L3("main_view_dom_ready"),pEA()"#);
    }

    #[test]
    fn online_dom_ready_hook_uses_main_view_context() {
        let text = r#"a.webContents.on("dom-ready",()=>{first()});const view=".vite/build/mainView.js";s.webContents.on("dom-ready",()=>{pEA()});"#;

        let hook = find_online_dom_ready_hook(text).unwrap().unwrap();

        assert_eq!(hook.receiver, "s.webContents");
        assert_eq!(hook.body, "pEA()");
    }

    #[test]
    fn online_dom_ready_strip_restores_original_handler_body() {
        let text = r#"s.webContents.on("dom-ready",()=>{L3("main_view_dom_ready"),pEA();s.webContents.executeJavaScript("(()=>{})()").catch(()=>{})});/*__claudeZhOnlineLocaleMain*/"#;

        let stripped = strip_existing_online_patch(text, ONLINE_MARKER).unwrap();

        assert_eq!(
            stripped,
            r#"s.webContents.on("dom-ready",()=>{L3("main_view_dom_ready"),pEA()});"#
        );
    }

    #[test]
    fn online_dom_ready_hook_errors_on_multiple_main_view_markers() {
        let text = r#"a.webContents.on("dom-ready",()=>{L3("main_view_dom_ready")});s.webContents.on("dom-ready",()=>{L3("main_view_dom_ready"),pEA()});"#;

        let error = find_online_dom_ready_hook(text).unwrap_err();

        assert!(error
            .to_string()
            .contains("多个 main_view_dom_ready dom-ready 注入点"));
    }

    // ── asar 整数安全测试 ──────────────────────────────────────────────

    /// 构造一个合法的最小 asar 二进制数据。
    /// 返回 (data, header_string)。
    fn make_asar_data(header_json: &str) -> Vec<u8> {
        let header_bytes = header_json.as_bytes();
        let string_size = header_bytes.len();
        let payload_size = align4(4 + string_size).unwrap();
        let pickle_size = 4 + payload_size;

        let mut data = Vec::new();
        data.extend_from_slice(&4u32.to_le_bytes());
        data.extend_from_slice(&u32::try_from(pickle_size).unwrap().to_le_bytes());
        data.extend_from_slice(&u32::try_from(payload_size).unwrap().to_le_bytes());
        data.extend_from_slice(&i32::try_from(string_size).unwrap().to_le_bytes());
        data.extend_from_slice(header_bytes);
        data.resize(8 + pickle_size, 0);
        data
    }

    #[test]
    fn asar_data_too_short_returns_error() {
        // 不足 16 字节
        let err = AsarArchive::from_data("test.asar".into(), vec![0u8; 10]).unwrap_err();
        assert!(err.to_string().contains("Unsupported app.asar header"));
    }

    #[test]
    fn asar_negative_string_size_returns_error() {
        // header_size = 8 (enough for payload_size + string_size)
        // payload_size = 0, string_size = -1
        let mut data = Vec::new();
        data.extend_from_slice(&4u32.to_le_bytes());        // size_pickle = 4
        data.extend_from_slice(&8u32.to_le_bytes());        // header_size = 8
        data.extend_from_slice(&0u32.to_le_bytes());        // payload_size = 0
        data.extend_from_slice(&(-1i32).to_le_bytes());     // string_size = -1
        data.resize(24, 0); // ensure data.len() >= 8 + header_size

        let err = AsarArchive::from_data("test.asar".into(), data).unwrap_err();
        assert!(err.to_string().contains("string_size 为负数"));
    }

    #[test]
    fn asar_header_size_overflow_returns_error() {
        // header_size = usize::MAX → 8 + header_size 溢出
        let mut data = vec![0u8; 20];
        data[0..4].copy_from_slice(&4u32.to_le_bytes());
        data[4..8].copy_from_slice(&u32::MAX.to_le_bytes()); // header_size = 4294967295

        let err = AsarArchive::from_data("test.asar".into(), data).unwrap_err();
        // 应被 data.len() < 8 + header_size 或溢出检查拦截
        assert!(err.to_string().contains("Unsupported app.asar"));
    }

    #[test]
    fn asar_payload_size_mismatch_returns_error() {
        // 手工构造 payload_size 错误的 header
        let header_json = r#"{"files":{}}"#;
        let string_size = header_json.len(); // 12
        let correct_payload = align4(4 + string_size).unwrap(); // 16

        let mut data = Vec::new();
        data.extend_from_slice(&4u32.to_le_bytes());
        data.extend_from_slice(&(4 + u32::try_from(correct_payload).unwrap()).to_le_bytes()); // header_size 正确
        data.extend_from_slice(&(u32::try_from(correct_payload).unwrap() + 8).to_le_bytes()); // payload_size 故意错误
        data.extend_from_slice(&i32::try_from(string_size).unwrap().to_le_bytes());
        data.extend_from_slice(header_json.as_bytes());
        data.resize(8 + 4 + correct_payload, 0);

        let err = AsarArchive::from_data("test.asar".into(), data).unwrap_err();
        assert!(err.to_string().contains("Unsupported app.asar header pickle"));
    }

    #[test]
    fn asar_entry_offset_exceeds_data_returns_error() {
        let header_json =
            r#"{"files":{"a.txt":{"offset":"999999","size":10}}}"#;
        let data = make_asar_data(header_json);

        let asar = AsarArchive::from_data("test.asar".into(), data).unwrap();
        let err = asar.read_text("a.txt").unwrap_err();
        assert!(err.to_string().contains("bounds 无效"));
    }

    #[test]
    fn asar_entry_size_exceeds_data_returns_error() {
        let header_json =
            r#"{"files":{"a.txt":{"offset":"0","size":999999}}}"#;
        let data = make_asar_data(header_json);

        let asar = AsarArchive::from_data("test.asar".into(), data).unwrap();
        let err = asar.read_text("a.txt").unwrap_err();
        assert!(err.to_string().contains("bounds 无效"));
    }

    #[test]
    fn asar_normal_file_roundtrip_works() {
        let body = b"hello world";
        let header_json = format!(
            r#"{{"files":{{"a.txt":{{"offset":"0","size":{}}}}}}}"#,
            body.len()
        );
        let mut data = make_asar_data(&header_json);
        data.extend_from_slice(body);

        let asar = AsarArchive::from_data("test.asar".into(), data).unwrap();
        assert_eq!(asar.read_text("a.txt").unwrap(), "hello world");
    }

    #[test]
    fn asar_replace_file_and_save_roundtrip() {
        let body = b"hello";
        let header_json = format!(
            r#"{{"files":{{"a.txt":{{"offset":"0","size":{}}}}}}}"#,
            body.len()
        );
        let mut data = make_asar_data(&header_json);
        data.extend_from_slice(body);

        let mut asar = AsarArchive::from_data("test.asar".into(), data).unwrap();
        assert!(asar.replace_file("a.txt", b"new content!").unwrap());
        assert_eq!(asar.read_text("a.txt").unwrap(), "new content!");
    }

    #[test]
    fn asar_shift_offsets_with_negative_delta_works() {
        let body_a = b"aaa";
        let body_b = b"bbbbb";
        let header_json = format!(
            r#"{{"files":{{"a.txt":{{"offset":"0","size":{}}},"b.txt":{{"offset":"3","size":{}}}}}}}"#,
            body_a.len(),
            body_b.len()
        );
        let mut data = make_asar_data(&header_json);
        data.extend_from_slice(body_a);
        data.extend_from_slice(body_b);

        let mut asar = AsarArchive::from_data("test.asar".into(), data).unwrap();
        // 替换 a.txt 为更短的内容 → delta 为负
        assert!(asar.replace_file("a.txt", b"x").unwrap());
        // b.txt 应该仍然可读
        assert_eq!(asar.read_text("b.txt").unwrap(), "bbbbb");
    }

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

    // ── align4 整数安全测试 ──────────────────────────────────────────────

    #[test]
    fn align4_returns_none_on_overflow() {
        // 接近 usize::MAX 时 +3 溢出
        assert!(align4(usize::MAX).is_none());
        assert!(align4(usize::MAX - 1).is_none());
        assert!(align4(usize::MAX - 2).is_none());
        assert_eq!(align4(usize::MAX - 3), Some(usize::MAX - 3));
    }

    #[test]
    fn align4_aligns_correctly() {
        assert_eq!(align4(0), Some(0));
        assert_eq!(align4(1), Some(4));
        assert_eq!(align4(4), Some(4));
        assert_eq!(align4(5), Some(8));
    }
}
