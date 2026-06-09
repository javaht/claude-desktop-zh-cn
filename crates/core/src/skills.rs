use crate::{
    error::{err, Result},
    fs_utils::{load_json_object_or_backup, now_millis, write_json},
    logging::{LogSink, LogSinkExt},
};
use chrono::{SecondsFormat, Utc};
use serde_json::{json, Map, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
};

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{fs_utils::read_json, logging::NoopLogger};
    use std::fs;

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
}
