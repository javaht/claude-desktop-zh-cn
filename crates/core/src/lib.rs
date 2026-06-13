mod asar;
mod error;
mod fs_utils;
mod frontend_locale;
mod frontend_patch;
mod hardcoded;
mod install;
mod logging;
mod menu_patch;
mod online_dom;
mod record;
mod resources;
mod skills;
mod types;

pub use asar::*;
pub use error::*;
pub use fs_utils::*;
pub use frontend_locale::*;
pub use frontend_patch::*;
pub use hardcoded::*;
pub use install::*;
pub use logging::*;
pub use menu_patch::*;
pub use online_dom::*;
pub use record::*;
pub use resources::*;
pub use skills::*;
pub use types::*;

use std::{
    fs,
    path::Path,
};

pub const ASAR_PATCH_TARGET: &str = ".vite/build/index.js";

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
