#[cfg(not(any(target_os = "macos", windows)))]
use claude_zh_core::{err, InstallRequest, LogSink, Result};
#[cfg(not(any(target_os = "macos", windows)))]
use std::path::Path;

#[cfg(target_os = "macos")] mod macos;
#[cfg(target_os = "macos")] pub(crate) use macos::{platform_install_patch, platform_restore_patch, launch_claude};

#[cfg(windows)] mod windows;
#[cfg(windows)] pub(crate) use windows::{platform_install_patch, platform_restore_patch, launch_claude};

#[cfg(not(any(target_os = "macos", windows)))]
pub(crate) fn launch_claude(_app: &Path, _logger: &dyn LogSink) {}

#[cfg(not(any(target_os = "macos", windows)))]
pub(crate) fn platform_install_patch(
    _resources: &Path,
    _req: &InstallRequest,
    _logger: &dyn LogSink,
) -> Result<()> {
    err("unsupported platform")
}

#[cfg(not(any(target_os = "macos", windows)))]
pub(crate) fn platform_restore_patch(_dry_run: bool, _logger: &dyn LogSink) -> Result<()> {
    err("unsupported platform")
}
