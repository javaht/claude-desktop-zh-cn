use crate::{
    error::{err, Result},
    fs_utils::read_json,
    types::LanguagePack,
};
use regex::Regex;
use std::{
    ffi::OsStr,
    fs,
    path::{Path, PathBuf},
};

pub const BASE_LANGUAGE_LIST: &str =
    r#"["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID""#;

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fs_utils::now_millis;
    use std::fs;

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
}
