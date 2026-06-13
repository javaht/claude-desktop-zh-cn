use std::{collections::BTreeMap, path::Path};

use crate::{asar::patch_asar_text, LogSink, Result};

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
