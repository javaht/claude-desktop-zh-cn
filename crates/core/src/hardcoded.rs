use aho_corasick::AhoCorasick;
use std::{fs, path::Path};

use crate::{err, CoreError, LogSink, LogSinkExt, Result};

pub fn patch_hardcoded_frontend(
    assets_dir: &Path,
    replacements_path: &Path,
    logger: &dyn LogSink,
) -> Result<()> {
    let replacements = hardcoded_replacements(replacements_path)?;
    let replacement_matcher = AhoCorasick::new(replacements.iter().map(|(source, _)| source))
        .map_err(|error| CoreError::Message(format!("硬编码匹配器构建失败: {error}")))?;
    let files = crate::js_files(assets_dir)?;
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
    let data = crate::read_json(path)?;
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
}
