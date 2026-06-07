use aho_corasick::AhoCorasick;
use chrono::{Local, SecondsFormat, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::OsStr,
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use thiserror::Error;

pub const BASE_LANGUAGE_LIST: &str =
    r#"["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID""#;
pub const ASAR_PATCH_TARGET: &str = ".vite/build/index.js";
pub const ONLINE_MARKER: &str = "__claudeZhOnlineLocaleMain";
const ASAR_BLOCK_SIZE: usize = 4 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("{0}")]
    Message(String),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("plist error: {0}")]
    Plist(#[from] plist::Error),
    #[error("regex error: {0}")]
    Regex(#[from] regex::Error),
    #[error("walkdir error: {0}")]
    Walkdir(#[from] walkdir::Error),
}

pub type Result<T> = std::result::Result<T, CoreError>;

pub fn err<T>(message: impl Into<String>) -> Result<T> {
    Err(CoreError::Message(message.into()))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogEvent {
    pub level: String,
    pub message: String,
}

pub trait LogSink {
    fn log(&self, level: &str, message: &str);
}

pub trait LogSinkExt: LogSink {
    fn info(&self, message: impl AsRef<str>) {
        self.log("info", message.as_ref());
    }

    fn warn(&self, message: impl AsRef<str>) {
        self.log("warn", message.as_ref());
    }

    fn error(&self, message: impl AsRef<str>) {
        self.log("error", message.as_ref());
    }
}

impl<T: LogSink + ?Sized> LogSinkExt for T {}

#[derive(Clone, Copy)]
pub struct StdoutLogger;

impl LogSink for StdoutLogger {
    fn log(&self, level: &str, message: &str) {
        println!("[{level}] {message}");
    }
}

#[derive(Clone, Copy)]
pub struct NoopLogger;

impl LogSink for NoopLogger {
    fn log(&self, _level: &str, _message: &str) {}
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallRequest {
    pub language: String,
    pub mode: String,
    pub launch_after: bool,
    pub dry_run: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliRequest {
    pub action: String,
    pub install: Option<InstallRequest>,
    pub enabled: Option<bool>,
    pub resources_path: Option<PathBuf>,
    pub log_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvironmentReport {
    pub platform: String,
    pub arch: String,
    pub resources_dir: Option<String>,
    pub resources_ok: bool,
    pub resource_issues: Vec<String>,
    pub claude_path: Option<String>,
    pub resources_path: Option<String>,
    pub install_kind: Option<String>,
    pub is_admin: bool,
    pub needs_admin: bool,
    pub current_locale: Option<String>,
    pub backup_count: usize,
    pub cc_switch_skills_dir: Option<String>,
    pub skills_plugin_root: Option<String>,
    pub auto_updates_enabled: Option<bool>,
    pub warnings: Vec<String>,
}

#[derive(Clone)]
pub struct LanguagePack {
    pub frontend: PathBuf,
    pub hardcoded: PathBuf,
    pub desktop: PathBuf,
    pub statsig: PathBuf,
    pub localizable: PathBuf,
}

#[derive(Clone, Copy)]
pub struct InstallPaths<'a> {
    pub source_resources: &'a Path,
    pub target_resources: &'a Path,
    pub mac_app_root: Option<&'a Path>,
}

pub fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

pub fn read_json(path: &Path) -> Result<Value> {
    let text = fs::read_to_string(path)?;
    Ok(serde_json::from_str(&text)?)
}

pub fn write_json(path: &Path, data: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension(format!(
        "{}.tmp",
        path.extension().and_then(OsStr::to_str).unwrap_or("json")
    ));
    let mut file = fs::File::create(&tmp)?;
    serde_json::to_writer_pretty(&mut file, data)?;
    file.write_all(b"\n")?;
    fs::rename(tmp, path)?;
    Ok(())
}

pub fn load_json_object_or_backup(path: &Path, logger: &dyn LogSink) -> Result<Map<String, Value>> {
    if !path.exists() {
        return Ok(Map::new());
    }
    match read_json(path) {
        Ok(Value::Object(map)) => Ok(map),
        _ => {
            let backup = path.with_extension("json.bak-invalid");
            logger.warn(format!(
                "JSON 无效，已备份并重建: {} -> {}",
                path.display(),
                backup.display()
            ));
            let _ = fs::copy(path, backup);
            Ok(Map::new())
        }
    }
}

pub fn copy_file(src: &Path, dst: &Path) -> Result<()> {
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(src, dst)?;
    Ok(())
}

pub fn remove_path(path: &Path) -> Result<()> {
    if path.is_dir() && !path.is_symlink() {
        fs::remove_dir_all(path)?;
    } else if path.exists() || path.is_symlink() {
        fs::remove_file(path)?;
    }
    Ok(())
}

pub fn sha256_hex(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}

fn required_language_resource_names() -> Vec<String> {
    let mut names = Vec::new();
    for lang in ["zh-CN", "zh-TW", "zh-HK"] {
        names.extend([
            format!("frontend-{lang}.json"),
            format!("frontend-hardcoded-{lang}.json"),
            format!("desktop-{lang}.json"),
            format!("statsig-{lang}.json"),
        ]);
    }
    names
}

pub fn verify_language_resource_files(resources: &Path) -> Vec<String> {
    let mut issues = Vec::new();
    for name in required_language_resource_names() {
        let path = resources.join(name);
        if !path.is_file() {
            issues.push(format!("missing resource: {}", path.display()));
        }
    }
    issues
}

pub fn verify_language_resources(resources: &Path) -> Vec<String> {
    let mut issues = Vec::new();
    for lang in ["zh-CN", "zh-TW", "zh-HK"] {
        for name in [
            format!("frontend-{lang}.json"),
            format!("frontend-hardcoded-{lang}.json"),
            format!("desktop-{lang}.json"),
            format!("statsig-{lang}.json"),
        ] {
            let path = resources.join(name);
            if !path.is_file() {
                issues.push(format!("缺少资源: {}", path.display()));
            } else if let Err(error) = read_json(&path) {
                issues.push(format!("JSON 无效: {} ({error})", path.display()));
            }
        }
    }
    for name in [
        "manifest.json",
        "manifest-zh-TW.json",
        "manifest-zh-HK.json",
    ] {
        let path = resources.join(name);
        if path.exists() {
            if let Err(error) = read_json(&path) {
                issues.push(format!("JSON 无效: {} ({error})", path.display()));
            }
        }
    }
    issues
}

pub fn language_pack(resources: &Path, lang: &str) -> Result<LanguagePack> {
    if !matches!(lang, "zh-CN" | "zh-TW" | "zh-HK") {
        return err(format!("不支持的语言: {lang}"));
    }
    let localizable_specific = resources.join(format!("Localizable-{lang}.strings"));
    let pack = LanguagePack {
        frontend: resources.join(format!("frontend-{lang}.json")),
        hardcoded: resources.join(format!("frontend-hardcoded-{lang}.json")),
        desktop: resources.join(format!("desktop-{lang}.json")),
        statsig: resources.join(format!("statsig-{lang}.json")),
        localizable: if localizable_specific.is_file() {
            localizable_specific
        } else {
            resources.join("Localizable.strings")
        },
    };
    for path in [
        &pack.frontend,
        &pack.hardcoded,
        &pack.desktop,
        &pack.statsig,
        &pack.localizable,
    ] {
        if !path.is_file() {
            return err(format!("缺少必要资源: {}", path.display()));
        }
    }
    Ok(pack)
}

pub fn language_list_regex() -> Result<Regex> {
    Regex::new(
        r#"\["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"(?:(?:,"zh-CN")|(?:,"zh-TW")|(?:,"zh-HK"))*\]"#,
    )
    .map_err(Into::into)
}

pub fn js_files(dir: &Path) -> Result<Vec<PathBuf>> {
    if !dir.is_dir() {
        return err(format!("未找到前端 JS 目录: {}", dir.display()));
    }
    let mut out = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(OsStr::to_str) == Some("js") {
            out.push(path);
        }
    }
    out.sort();
    Ok(out)
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
    out.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
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

pub fn set_config_locale(path: &Path, lang: &str, logger: &dyn LogSink) -> Result<()> {
    let mut data = load_json_object_or_backup(path, logger)?;
    data.insert("locale".to_string(), Value::String(lang.to_string()));
    write_json(path, &Value::Object(data))?;
    logger.info(format!("已写入语言配置: {}", path.display()));
    Ok(())
}

pub fn config_library_set_auto_updates(
    path: &Path,
    enabled: bool,
    logger: &dyn LogSink,
) -> Result<()> {
    fs::create_dir_all(path)?;
    let meta_path = path.join("_meta.json");
    let mut meta = load_json_object_or_backup(&meta_path, logger)?;
    let config_id = meta
        .get("appliedId")
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| {
            fs::read_dir(path).ok().and_then(|entries| {
                let mut names: Vec<String> = entries
                    .flatten()
                    .filter_map(|entry| {
                        let file_name = entry.file_name().to_string_lossy().to_string();
                        if file_name.ends_with(".json") && file_name != "_meta.json" {
                            Some(file_name.trim_end_matches(".json").to_string())
                        } else {
                            None
                        }
                    })
                    .collect();
                names.sort();
                names.into_iter().next()
            })
        })
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let config_path = path.join(format!("{config_id}.json"));
    let mut config = load_json_object_or_backup(&config_path, logger)?;
    config.insert("disableAutoUpdates".to_string(), Value::Bool(!enabled));
    meta.insert("appliedId".to_string(), Value::String(config_id.clone()));
    let entries = meta
        .entry("entries")
        .or_insert_with(|| Value::Array(Vec::new()));
    if !entries.as_array().is_some_and(|items| {
        items
            .iter()
            .any(|item| item.get("id").and_then(Value::as_str) == Some(config_id.as_str()))
    }) {
        if !entries.is_array() {
            *entries = Value::Array(Vec::new());
        }
        entries
            .as_array_mut()
            .unwrap()
            .push(json!({"id": config_id, "name": "Default"}));
    }
    write_json(&config_path, &Value::Object(config))?;
    write_json(&meta_path, &Value::Object(meta))?;
    Ok(())
}

pub fn auto_updates_enabled(paths: Vec<PathBuf>) -> Option<bool> {
    for path in paths {
        let meta = read_json(&path.join("_meta.json")).ok()?;
        let config_id = meta.get("appliedId").and_then(Value::as_str)?;
        let config = read_json(&path.join(format!("{config_id}.json"))).ok()?;
        return Some(
            !config
                .get("disableAutoUpdates")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        );
    }
    None
}

pub fn read_frontmatter(path: &Path) -> Result<BTreeMap<String, String>> {
    let text = fs::read_to_string(path)?;
    let mut map = BTreeMap::new();
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some("---") {
        return Ok(map);
    }
    for line in lines {
        let line = line.trim_end();
        if line.trim() == "---" {
            break;
        }
        if let Some((key, value)) = line.split_once(':') {
            map.insert(
                key.trim().to_string(),
                value.trim().trim_matches('"').to_string(),
            );
        }
    }
    Ok(map)
}

#[derive(Clone)]
struct SkillInfo {
    name: String,
    description: String,
    path: PathBuf,
}

fn discover_cc_switch_skills(skills_dir: &Path) -> Result<Vec<SkillInfo>> {
    if !skills_dir.is_dir() {
        return err(format!(
            "CC Switch skills 目录不存在: {}",
            skills_dir.display()
        ));
    }
    let mut out = Vec::new();
    for entry in fs::read_dir(skills_dir)? {
        let entry = entry?;
        let path = entry.path();
        let skill_md = path.join("SKILL.md");
        if !path.is_dir() || !skill_md.is_file() {
            continue;
        }
        let frontmatter = read_frontmatter(&skill_md)?;
        let name = frontmatter
            .get("name")
            .filter(|value| !value.trim().is_empty())
            .cloned()
            .unwrap_or_else(|| entry.file_name().to_string_lossy().to_string());
        if name.contains('/') || name.contains('\\') || name == "." || name == ".." {
            continue;
        }
        out.push(SkillInfo {
            name,
            description: frontmatter.get("description").cloned().unwrap_or_default(),
            path,
        });
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

fn load_skills_manifest(path: &Path, logger: &dyn LogSink) -> Result<Map<String, Value>> {
    let mut data = load_json_object_or_backup(path, logger)?;
    if !data.get("skills").is_some_and(Value::is_array) {
        data.insert("skills".to_string(), Value::Array(Vec::new()));
    }
    Ok(data)
}

fn path_within(path: &Path, parent: &Path) -> bool {
    path.strip_prefix(parent).is_ok()
}

pub fn sync_skills_impl(
    plugin_root: &Path,
    skills_dir: &Path,
    remove: bool,
    logger: &dyn LogSink,
) -> Result<()> {
    let desktop_skills = plugin_root.join("skills");
    fs::create_dir_all(&desktop_skills)?;
    let manifest_path = plugin_root.join("manifest.json");
    let mut manifest = load_skills_manifest(&manifest_path, logger)?;
    let cc_skills = discover_cc_switch_skills(skills_dir)?;
    let mut skills = manifest
        .remove("skills")
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default();

    if remove {
        let cc_root = skills_dir
            .canonicalize()
            .unwrap_or_else(|_| skills_dir.to_path_buf());
        let mut removed = BTreeSet::new();
        let mut skipped = 0usize;
        for skill in &cc_skills {
            let target = desktop_skills.join(&skill.name);
            if !target.is_symlink() {
                skipped += 1;
                continue;
            }
            let resolved = fs::read_link(&target)
                .ok()
                .and_then(|p| p.canonicalize().ok())
                .unwrap_or_default();
            if !path_within(&resolved, &cc_root) {
                skipped += 1;
                continue;
            }
            fs::remove_file(&target)?;
            removed.insert(skill.name.clone());
            logger.info(format!("已删除同步: {}", skill.name));
        }
        skills.retain(|item| {
            !item
                .get("name")
                .and_then(Value::as_str)
                .is_some_and(|name| removed.contains(name))
        });
        logger.info(format!(
            "取消同步完成：删除 {} 个，跳过 {skipped} 个",
            removed.len()
        ));
    } else {
        let mut existing: BTreeSet<String> = skills
            .iter()
            .filter_map(|item| {
                item.get("name")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .collect();
        let mut added = 0usize;
        let mut skipped = 0usize;
        let now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        for skill in &cc_skills {
            let target = desktop_skills.join(&skill.name);
            if target.exists() || target.is_symlink() || existing.contains(&skill.name) {
                skipped += 1;
                continue;
            }
            create_dir_symlink(&skill.path, &target)?;
            skills.push(json!({
                "skillId": skill.name,
                "name": skill.name,
                "description": skill.description,
                "creatorType": "user",
                "syncManaged": false,
                "updatedAt": now,
                "enabled": true
            }));
            existing.insert(skill.name.clone());
            added += 1;
            logger.info(format!("已同步: {}", skill.name));
        }
        logger.info(format!("同步完成：新增 {added} 个，跳过 {skipped} 个"));
    }

    manifest.insert("skills".to_string(), Value::Array(skills));
    manifest.insert("lastUpdated".to_string(), json!(now_millis()));
    if manifest_path.exists() {
        let backup = manifest_path.with_file_name("manifest.json.bak-before-cc-switch-sync");
        let _ = fs::copy(&manifest_path, backup);
    }
    write_json(&manifest_path, &Value::Object(manifest))?;
    Ok(())
}

#[cfg(unix)]
fn create_dir_symlink(src: &Path, dst: &Path) -> Result<()> {
    std::os::unix::fs::symlink(src, dst)?;
    Ok(())
}

#[cfg(windows)]
fn create_dir_symlink(src: &Path, dst: &Path) -> Result<()> {
    std::os::windows::fs::symlink_dir(src, dst)?;
    Ok(())
}

pub fn find_skills_plugin_root(base: &Path) -> Option<PathBuf> {
    if !base.is_dir() {
        return None;
    }
    let mut candidates = Vec::new();
    for org in fs::read_dir(base).ok()?.flatten().map(|entry| entry.path()) {
        if !org.is_dir() {
            continue;
        }
        for plugin in fs::read_dir(org).ok()?.flatten().map(|entry| entry.path()) {
            if plugin.join("manifest.json").is_file() && plugin.join("skills").is_dir() {
                candidates.push(plugin);
            }
        }
    }
    candidates.sort_by_key(|path| {
        fs::metadata(path.join("manifest.json"))
            .and_then(|m| m.modified())
            .ok()
    });
    candidates.pop()
}

fn align4(value: usize) -> usize {
    value + ((4 - (value % 4)) % 4)
}

#[derive(Clone)]
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
        let string_size = i32::from_le_bytes(header_pickle[4..8].try_into().unwrap()) as usize;
        if payload_size != align4(4 + string_size) || header_size != 4 + payload_size {
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
        let start = 8 + self.header_size + offset;
        let end = start + size;
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
        let header = encode_asar_header_dynamic(&header_string);
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
                    set_entry_offset(entry, ((offset as isize) + delta) as usize);
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

pub fn encode_asar_header_dynamic(header_string: &str) -> Vec<u8> {
    let header_bytes = header_string.as_bytes();
    let payload_size = align4(4 + header_bytes.len());
    let pickle_size = 4 + payload_size;
    let mut out = Vec::with_capacity(8 + pickle_size);
    out.extend_from_slice(&(4u32).to_le_bytes());
    out.extend_from_slice(&(pickle_size as u32).to_le_bytes());
    out.extend_from_slice(&(payload_size as u32).to_le_bytes());
    out.extend_from_slice(&(header_bytes.len() as i32).to_le_bytes());
    out.extend_from_slice(header_bytes);
    out.resize(8 + pickle_size, 0);
    out
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
        let _ = update_macos_asar_integrity(app_root, &header_string);
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
    Ok(format!(
        r#"(()=>{{try{{const L="{lang}",M={mapping_json};localStorage.setItem("spa:locale",L);document.documentElement&&document.documentElement.setAttribute("lang",L);const N=s=>(s||"").replace(/\s+/g," ").trim();const G=[[/^Morning, (.+)$/,"早上好，$1"],[/^Good morning, (.+)$/,"早上好，$1"],[/^Afternoon, (.+)$/,"下午好，$1"],[/^Good afternoon, (.+)$/,"下午好，$1"],[/^Evening, (.+)$/,"晚上好，$1"],[/^Good evening, (.+)$/,"晚上好，$1"],[/^Delete (\d+) chat$/,"删除 $1 个聊天"],[/^Delete (\d+) chats$/,"删除 $1 个聊天"]];const R=s=>{{const n=N(s);if(M[n])return M[n];for(const [r,t]of G){{const m=n.match(r);if(m)return t.replace("$1",m[1])}}}};const X=new Set(["SCRIPT","STYLE","NOSCRIPT"]);function T(){{try{{const b=document.body||document.documentElement;if(!b)return;const w=document.createTreeWalker(b,NodeFilter.SHOW_TEXT,{{acceptNode(n){{const p=n.parentElement;if(!p||X.has(p.tagName)||p.closest("[contenteditable]")||!R(n.nodeValue))return NodeFilter.FILTER_REJECT;return NodeFilter.FILTER_ACCEPT}}}});let n;while(n=w.nextNode()){{const v=R(n.nodeValue);if(v)n.nodeValue=v}}document.querySelectorAll("[aria-label],[title],[placeholder],input,textarea").forEach(e=>{{["aria-label","title","placeholder","value"].forEach(a=>{{try{{if(a==="value"&&!(e.matches("input[type=button],input[type=submit]")))return;let v=e.getAttribute?e.getAttribute(a):void 0;if(v==null&&a in e)v=e[a];const t=R(v);if(t){{if(e.setAttribute)e.setAttribute(a,t);try{{if(a in e)e[a]=t}}catch{{}}}}}}catch{{}}}})}})}}catch{{}}}}T();new MutationObserver(()=>{{clearTimeout(window.__claudeZhDomTimer);window.__claudeZhDomTimer=setTimeout(T,30)}}).observe(document.documentElement,{{subtree:true,childList:true,characterData:true,attributes:true}})}}catch(e){{}}}})()"#
    ))
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
        let hook = Regex::new(
            r#"(?P<receiver>[A-Za-z_$][A-Za-z0-9_$]*)\.webContents\.on\("dom-ready",\(\)=>\{(?P<body>[^{}]*)\}\);"#,
        )?;
        if let Some(caps) = hook.captures(&stripped) {
            let full = caps.get(0).unwrap();
            let full_range = full.start()..full.end();
            let receiver = caps.name("receiver").unwrap().as_str();
            let body = caps.name("body").unwrap().as_str();
            let injection = format!(
                r#"{receiver}.webContents.on("dom-ready",()=>{{{body};{receiver}.webContents.executeJavaScript({}).catch(()=>{{}})}});/*{marker}*/"#,
                serde_json::to_string(&script)?
            );
            let mut patched = stripped;
            patched.replace_range(full_range, &injection);
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
        r#"[A-Za-z_$][A-Za-z0-9_$]*\.webContents\.on\("dom-ready",\(\)=>\{{.*?executeJavaScript\("(?:\\.|[^"])*"\)\.catch\(\(\)=>\{{\}}\)\}}\);/\*{}\*/"#,
        regex::escape(marker)
    ))?;
    Ok(pattern.replace_all(text, "").to_string())
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
    use std::fs;

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
    fn language_resource_validation_catches_missing_files() {
        let root = std::env::temp_dir().join(format!("claude-zh-core-test-{}", now_millis()));
        fs::create_dir_all(&root).unwrap();
        let issues = verify_language_resources(&root);
        assert!(issues
            .iter()
            .any(|issue| issue.contains("frontend-zh-CN.json")));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn skills_sync_does_not_override_existing_skill() {
        let root = std::env::temp_dir().join(format!("claude-zh-skills-test-{}", now_millis()));
        let plugin = root.join("plugin");
        let desktop_skills = plugin.join("skills");
        let source = root.join("cc");
        let source_skill = source.join("demo");
        fs::create_dir_all(&desktop_skills).unwrap();
        fs::create_dir_all(&source_skill).unwrap();
        fs::write(
            plugin.join("manifest.json"),
            r#"{"skills":[{"name":"demo","skillId":"demo"}]}"#,
        )
        .unwrap();
        fs::write(
            source_skill.join("SKILL.md"),
            "---\nname: demo\ndescription: demo\n---\n",
        )
        .unwrap();
        sync_skills_impl(&plugin, &source, false, &NoopLogger).unwrap();
        assert!(!desktop_skills.join("demo").exists());
        let manifest = read_json(&plugin.join("manifest.json")).unwrap();
        assert_eq!(manifest["skills"].as_array().unwrap().len(), 1);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn asar_header_round_trip_encodes_parseable_header() {
        let header = r#"{"files":{"a.txt":{"offset":"0","size":3}}}"#;
        let encoded = encode_asar_header_dynamic(header);
        assert_eq!(&encoded[0..4], &(4u32).to_le_bytes());
        let header_size = u32::from_le_bytes(encoded[4..8].try_into().unwrap()) as usize;
        assert_eq!(encoded.len(), 8 + header_size);
    }
}
