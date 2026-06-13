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
mod restore;
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
pub use restore::*;
pub use skills::*;
pub use types::*;

pub const ASAR_PATCH_TARGET: &str = ".vite/build/index.js";

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
