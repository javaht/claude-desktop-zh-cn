use regex::Regex;
use serde_json::Value;
use std::{collections::BTreeMap, ops::Range, path::Path};

use crate::hardcoded::hardcoded_replacements;
use crate::{asar::patch_asar_text, err, LogSink, LogSinkExt, Result};

pub const ONLINE_MARKER: &str = "__claudeZhOnlineLocaleMain";

pub fn build_online_translation_map(
    installed_i18n: &Path,
    pack: &crate::LanguagePack,
) -> Result<BTreeMap<String, String>> {
    let en = crate::read_json(&installed_i18n.join("en-US.json"))?;
    let zh = crate::read_json(&pack.frontend)?;
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
        r#"(()=>{{try{{const L={lang_json},M={mapping_json};localStorage.setItem("spa:locale",L);document.documentElement&&document.documentElement.setAttribute("lang",L);const N=s=>(s||"").replace(/\s+/g," ").trim();const G=[[/^Morning, (.+)$/,"早上好，$1"],[/^Good morning, (.+)$/,"早上好，$1"],[/^Afternoon, (.+)$/,"下午好，$1"],[/^Good afternoon, (.+)$/,"下午好，$1"],[/^Evening, (.+)$/,"晚上好，$1"],[/^Good evening, (.+)$/,"晚上好，$1"],[/^It's late-night (.+)$/,"夜深了，$1"],[/^Good night, (.+)$/,"晚安，$1"],[/^Delete (\d+) chat$/,"删除 $1 个聊天"],[/^Delete (\d+) chats$/,"删除 $1 个聊天"],[/^Move (\d+) chat to a project$/,"将 $1 个聊天移至项目"],[/^Move (\d+) chats to a project$/,"将 $1 个聊天移至项目"],[/^Connection needs (\d+) field$/,"连接还需要填写 $1 个字段"],[/^Connection needs (\d+) fields$/,"连接还需要填写 $1 个字段"],[/^needs (\d+) field$/,"还需要填写 $1 个字段"],[/^needs (\d+) fields$/,"还需要填写 $1 个字段"],[/^Are you sure you want to delete (\d+) chat\? This cannot be undone\.$/,"你确定要删除 $1 个聊天吗？此操作无法撤消。"],[/^Are you sure you want to delete (\d+) chats\? This cannot be undone\.$/,"你确定要删除 $1 个聊天吗？此操作无法撤消。"],[/^Are you sure you want to permanently delete this chat\? This cannot be undone\.$/,"你确定要永久删除此聊天吗？此操作无法撤消。"],[/^Are you sure you want to permanently delete these chats\? This cannot be undone\.$/,"你确定要永久删除这些聊天吗？此操作无法撤消。"],[/^(\d+) selected$/,{selected_json}],[/^Delete (\d+) selected item$/,{delete_selected_json}],[/^Delete (\d+) selected items$/,{delete_selected_json}],[/^Mon$/,"周一"],[/^Tue$/,"周二"],[/^Wed$/,"周三"],[/^Thu$/,"周四"],[/^Fri$/,"周五"],[/^Sat$/,"周六"],[/^Sun$/,"周日"]];const R=s=>{{const n=N(s);if(M[n])return M[n];for(const [r,t]of G){{const m=n.match(r);if(m)return t.replace("$1",m[1])}}}};const X=new Set(["SCRIPT","STYLE","NOSCRIPT"]);const C='pre,code,kbd,samp,var,.hljs,.prism,.shiki,[class*="cm-line"],[class*="cm-content"],[class*="monaco-editor"],[data-testid*="code-block"],[data-language]';function T(){{try{{const b=document.body||document.documentElement;if(!b)return;const w=document.createTreeWalker(b,NodeFilter.SHOW_TEXT,{{acceptNode:n=>{{if(n.parentElement&&n.parentElement.closest(C))return NodeFilter.FILTER_REJECT;const t=n.textContent.trim();return t&&R(t)?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT}}}});const M=[];while(w.nextNode())M.push(w.currentNode);M.forEach(n=>{{const t=n.textContent.trim();const r=R(t);if(r)n.textContent=r}});document.querySelectorAll('[placeholder],[title],[aria-label],[aria-placeholder]').forEach(e=>{{['placeholder','title','aria-label','aria-placeholder'].forEach(a=>{{const v=e.getAttribute(a);if(v){{const r=R(v.trim());if(r)e.setAttribute(a,r)}}}})}});document.querySelectorAll('input[type="button"],input[type="submit"],button').forEach(e=>{{const v=e.value;if(v){{const r=R(v.trim());if(r)e.value=r}};const t=e.textContent.trim();if(t){{const r=R(t);if(r)e.textContent=r}}}})}}catch(e)}})();{lang_json};{mapping_json};{selected_json};{delete_selected_json}"#
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

#[cfg(test)]
mod tests {
    use super::*;

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
    fn online_dom_translation_script_skips_code_surfaces() {
        let mut mapping = BTreeMap::new();
        mapping.insert("System".to_string(), "系统".to_string());

        let script = build_online_dom_translation_script("zh-CN", &mapping).unwrap();

        assert!(script.contains("pre,code,kbd,samp,var"));
        assert!(script.contains("parentElement"));
        assert!(script.contains("closest(C)"));
        assert!(script.contains("NodeFilter.FILTER_REJECT"));
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
}
