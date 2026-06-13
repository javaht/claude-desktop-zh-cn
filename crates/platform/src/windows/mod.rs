#![cfg(windows)]

pub(super) mod backup;
pub(super) mod install;
pub(super) mod permissions;
pub(super) mod restore;

use std::process::{Command, Stdio};

use crate::logging::{hide_command_window, run_command};
use claude_zh_core::{LogSink, LogSinkExt, Result};

pub(super) const WATCHER_TASK: &str = "ClaudeDesktopZhCn-UpdateWatcher";

const WINDOWS_CLAUDE_PROCESS_TREE_FUNCTION: &str = r#"
function Get-ClaudeDesktopProcessTree {
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ExecutablePath -and
      (
        $_.ExecutablePath -like '*\WindowsApps\Claude_*' -or
        $_.ExecutablePath -like '*\AnthropicClaude\app-*\*'
      )
    })
  if (-not $all) {
    return @()
  }

  $anchors = @($all)
  if (-not $anchors) {
    return @()
  }

  $selected = @{}
  foreach ($proc in $anchors) {
    $selected[[int]$proc.ProcessId] = $true
  }

  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($proc in $all) {
      $procId = [int]$proc.ProcessId
      $parentId = [int]$proc.ParentProcessId
      if ($selected.ContainsKey($procId) -or $selected.ContainsKey($parentId)) {
        if (-not $selected.ContainsKey($procId)) {
          $selected[$procId] = $true
          $changed = $true
        }
        if ($parentId -ne 0 -and -not $selected.ContainsKey($parentId)) {
          $parent = $all | Where-Object { [int]$_.ProcessId -eq $parentId } | Select-Object -First 1
          if ($parent) {
            $selected[$parentId] = $true
            $changed = $true
          }
        }
      }
    }
  }

  @($all | Where-Object { $selected.ContainsKey([int]$_.ProcessId) })
}
"#;

fn windows_claude_stop_script() -> String {
    format!(
        "{}\nGet-ClaudeDesktopProcessTree |\n  ForEach-Object {{\n    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue\n  }}\n",
        WINDOWS_CLAUDE_PROCESS_TREE_FUNCTION
    )
}

pub(super) fn windows_claude_probe_script() -> String {
    format!(
        "{}\n$procs = @(Get-ClaudeDesktopProcessTree)\nif ($procs.Count -gt 0) {{\n  Write-Output (\"FOUND:\" + $procs.Count)\n  $procs | ForEach-Object {{ Write-Output (\" - PID=\" + $_.ProcessId + \" EXE=\" + $_.ExecutablePath) }}\n}} else {{\n  Write-Output \"NONE\"\n}}\n",
        WINDOWS_CLAUDE_PROCESS_TREE_FUNCTION
    )
}

pub(super) fn quit_claude(logger: &dyn LogSink) {
    logger.info("正在关闭 Claude Desktop 进程。");
    // 使用 PowerShell 精确匹配已知安装路径，避免误杀 Claude Code CLI
    let mut cmd = Command::new("powershell.exe");
    let script = windows_claude_stop_script();
    cmd.args([
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        script.as_str(),
    ]);
    hide_command_window(&mut cmd);
    let _ = run_command(cmd, logger, "关闭 Claude Desktop");
}

pub(crate) fn launch_claude(app: &std::path::Path, logger: &dyn LogSink) {
    let exe = [
        "Claude.exe",
        "claude.exe",
        r"app\Claude.exe",
        r"app\claude.exe",
    ]
    .iter()
    .map(|name| app.join(name))
    .find(|path| path.is_file());
    if let Some(exe) = exe {
        let mut cmd = Command::new(exe);
        hide_command_window(&mut cmd);
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let _ = cmd.spawn();
        logger.info("已启动 Claude Desktop");
    }
}

pub(super) fn unregister_update_watcher(logger: &dyn LogSink) -> Result<()> {
    let mut cmd = Command::new("schtasks");
    hide_command_window(&mut cmd);
    let removed = cmd
        .args(["/Delete", "/F", "/TN", WATCHER_TASK])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    if removed {
        logger.info("已移除旧的更新守护计划任务。");
    }
    Ok(())
}

// Re-exports for facade
pub(crate) use install::platform_install_patch;
pub(crate) use restore::platform_restore_patch;

#[cfg(test)]
mod tests {
    use super::windows_claude_stop_script;

    #[test]
    fn windows_quit_script_kills_inaccessible_claude_processes() {
        let script = windows_claude_stop_script();

        assert!(script.contains("Get-CimInstance Win32_Process"));
        assert!(script.contains("$_.ExecutablePath"));
        assert!(script.contains("ParentProcessId"));
        assert!(script.contains("WindowsApps\\Claude_*"));
        assert!(script.contains("AnthropicClaude\\app-*\\*"));
        assert!(
            script.contains("Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue")
        );
    }
}
