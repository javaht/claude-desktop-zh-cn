mod actions;
mod auto_update;
mod elevation;
mod environment;
mod logging;
mod os;
mod paths;
mod resources;

pub use actions::{
    install_patch, restore_patch, set_auto_updates, sync_cc_switch_skills, unsync_cc_switch_skills,
};
pub use auto_update::{auto_updates_enabled, parse_enabled_flag};
pub use elevation::{run_cli_request, run_elevated_cli};
pub use environment::{
    backup_count, current_locale, detect_claude, detect_environment, is_admin, platform_name,
};
#[cfg(windows)]
pub use environment::{
    detect_windows_claude_in_localappdata, detect_windows_claude_in_windowsapps,
};
pub use logging::{run_command, set_file_logger_silent_stdout, FileLogger};
pub use paths::{
    cc_switch_skills_dir, claude_config_paths, skills_plugin_root, user_home,
};
pub use resources::{
    install_resource_update, resolve_resources, resource_candidates, resource_release_manifest,
    ResourceReleaseManifest,
};

#[cfg(test)]
mod tests {
    #[cfg(windows)]
    #[test]
    fn windows_detection_helpers_exist() {
        let _ = super::detect_windows_claude_in_localappdata();
        let _ = super::detect_windows_claude_in_windowsapps();
    }
}
