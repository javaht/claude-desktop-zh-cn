//! Claude Desktop 自动更新策略读写。
//!
//! 目标：让 UI 上的「自动更新」开关真正影响 Claude Desktop 的更新行为，
//! 而不是写一份只有本工具自己看的影子配置。
//!
//! 实现要点：
//! - Windows：写机器级注册表 `HKLM\Software\Policies\Claude\disableAutoUpdates`
//!   （DWORD，1 = 禁用，0 = 启用）。Claude Desktop 官方企业策略字段同名。
//!   选择 HKLM 而非 HKCU 的原因：
//!     1. 提权子进程里 `HKEY_CURRENT_USER` 可能是 UAC 管理员账号的用户 hive，
//!        与原桌面用户不同，写入会写到错误用户；
//!     2. 官方文档明确支持 HKLM 路径；
//!     3. 一次写入全体用户生效，对多用户机器更可控。
//!
//!   写 HKLM\Software\Policies 需管理员，所以从 actions 层走 elevation 流程。
//!   读取用 KEY_READ（仅支持 64 位进程；本项目仅发 x64 构建）。
//! - macOS：通过 `defaults` 命令写入 `com.anthropic.claudefordesktop` 域的
//!   `disableAutoUpdates`（boolean）。`defaults` 走 CFPreferences 标准通道，
//!   自动处理缓存同步，无需直接读写 plist 文件。

use claude_zh_core::{LogSink, LogSinkExt, Result};

/// 设置 Claude Desktop 是否启用自动更新。
///
/// `enabled = true` → 启用自动更新（清除/设为 0）。
/// `enabled = false` → 禁用自动更新（设为 1）。
pub fn set_auto_updates(enabled: bool, logger: &dyn LogSink) -> Result<()> {
    logger.info(format!(
        "自动更新请求: {}",
        if enabled { "开启" } else { "停止" }
    ));
    platform::set_auto_updates_impl(enabled, logger)
}

/// 读取当前 Claude Desktop 自动更新开关状态。
///
/// 返回 `Some(true)` 表示自动更新已启用，`Some(false)` 表示已禁用，
/// `None` 表示读不到任何用户级策略（即从未设置过，Claude 默认行为：启用）。
pub fn auto_updates_enabled() -> Option<bool> {
    platform::auto_updates_enabled_impl()
}

/// 从 CLI 参数列表中解析 `--enabled` 标志（纯函数，便于单测）。
///
/// 支持 `--enabled true` 和 `--enabled=true` 两种形式。
/// 返回 `Ok(Some(true))` / `Ok(Some(false))` / `Ok(None)`（未出现）。
/// 重复出现、值缺失或值非法时返回 `Err(String)`。
pub fn parse_enabled_flag(args: &[String]) -> std::result::Result<Option<bool>, String> {
    let mut result: Option<bool> = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--enabled" {
            if result.is_some() {
                return Err("--enabled 重复出现".to_string());
            }
            let Some(val) = iter.next() else {
                return Err("--enabled 缺少值（期望 true 或 false）".to_string());
            };
            result = Some(parse_bool_value(val)?);
        } else if let Some(val) = arg.strip_prefix("--enabled=") {
            if result.is_some() {
                return Err("--enabled 重复出现".to_string());
            }
            result = Some(parse_bool_value(val)?);
        }
    }
    Ok(result)
}

fn parse_bool_value(val: &str) -> std::result::Result<bool, String> {
    match val {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err(format!("--enabled 无效值: {val}（期望 true 或 false）")),
    }
}

#[cfg(windows)]
mod platform {
    use claude_zh_core::{CoreError, LogSink, LogSinkExt, Result};
    use std::{ffi::OsStr, iter::once, os::windows::ffi::OsStrExt, ptr};
    use windows::core::PCWSTR;
    use windows::Win32::System::Registry::{
        RegCloseKey, RegCreateKeyExW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW, HKEY,
        HKEY_LOCAL_MACHINE, KEY_READ, KEY_WRITE, REG_DWORD, REG_OPTION_NON_VOLATILE,
        REG_VALUE_TYPE,
    };

    const SUBKEY: &str = r"Software\Policies\Claude";
    const VALUE_NAME: &str = "disableAutoUpdates";

    pub(super) fn set_auto_updates_impl(enabled: bool, logger: &dyn LogSink) -> Result<()> {
        let disable: u32 = if enabled { 0 } else { 1 };
        let subkey_w = to_wide(SUBKEY);
        let value_w = to_wide(VALUE_NAME);
        let mut hkey = HKEY::default();
        unsafe {
            RegCreateKeyExW(
                HKEY_LOCAL_MACHINE,
                PCWSTR(subkey_w.as_ptr()),
                0,
                PCWSTR::null(),
                REG_OPTION_NON_VOLATILE,
                KEY_WRITE,
                Some(ptr::null()),
                &mut hkey,
                None,
            )
            .ok()
            .map_err(|error| {
                CoreError::Message(format!(
                    "无法打开/创建注册表项 HKLM\\{SUBKEY}: {error}"
                ))
            })?;
        }
        let bytes = disable.to_le_bytes();
        let set_result = unsafe {
            RegSetValueExW(
                hkey,
                PCWSTR(value_w.as_ptr()),
                0,
                REG_DWORD,
                Some(&bytes),
            )
            .ok()
        };
        unsafe {
            let _ = RegCloseKey(hkey);
        }
        set_result.map_err(|error| {
            CoreError::Message(format!(
                "写入 HKLM\\{SUBKEY}\\{VALUE_NAME} 失败: {error}"
            ))
        })?;
        logger.info(format!(
            "已写入 HKLM\\{SUBKEY}\\{VALUE_NAME} = {disable}"
        ));
        Ok(())
    }

    pub(super) fn auto_updates_enabled_impl() -> Option<bool> {
        let subkey_w = to_wide(SUBKEY);
        let value_w = to_wide(VALUE_NAME);
        let mut hkey = HKEY::default();
        let open = unsafe {
            RegOpenKeyExW(
                HKEY_LOCAL_MACHINE,
                PCWSTR(subkey_w.as_ptr()),
                0,
                KEY_READ,
                &mut hkey,
            )
        };
        if open.is_err() {
            // 注册表项不存在 → 用户从未设置过策略
            return None;
        }
        let mut data = [0u8; 4];
        let mut data_len: u32 = data.len() as u32;
        let mut value_type = REG_VALUE_TYPE(0);
        let query = unsafe {
            RegQueryValueExW(
                hkey,
                PCWSTR(value_w.as_ptr()),
                None,
                Some(&mut value_type),
                Some(data.as_mut_ptr()),
                Some(&mut data_len),
            )
        };
        unsafe {
            let _ = RegCloseKey(hkey);
        }
        if query.is_err() {
            return None;
        }
        // 严格校验：只接受 4 字节 REG_DWORD。类型不匹配说明外部把
        // 别的数据塞到这个 key 下，UI 不应该误显示成"已设置"。
        if value_type != REG_DWORD || data_len != 4 {
            return None;
        }
        let raw = u32::from_le_bytes(data);
        Some(raw == 0)
    }

    fn to_wide(s: &str) -> Vec<u16> {
        OsStr::new(s).encode_wide().chain(once(0)).collect()
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use claude_zh_core::{CoreError, LogSink, LogSinkExt, Result};
    use std::process::Command;

    const PREF_DOMAIN: &str = "com.anthropic.claudefordesktop";
    const VALUE_KEY: &str = "disableAutoUpdates";

    /// 构造 `defaults write` 的参数列表（纯函数，便于单测）。
    pub(super) fn build_defaults_args(enabled: bool) -> Vec<String> {
        // enabled=true → 启用更新 → disableAutoUpdates=false
        // enabled=false → 禁用更新 → disableAutoUpdates=true
        let disable = !enabled;
        vec![
            "write".to_string(),
            PREF_DOMAIN.to_string(),
            VALUE_KEY.to_string(),
            "-bool".to_string(),
            disable.to_string(),
        ]
    }

    /// 解析 `defaults read` 的 stdout（纯函数，便于单测）。
    /// 返回 `Some(true)` 表示自动更新已启用，`Some(false)` 表示已禁用，
    /// `None` 表示无法解析（未设置或格式错误）。
    pub(super) fn parse_defaults_output(stdout: &str) -> Option<bool> {
        match stdout.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" => Some(false), // disableAutoUpdates=true → 自动更新禁用
            "0" | "false" | "no" => Some(true),  // disableAutoUpdates=false → 自动更新启用
            _ => None,
        }
    }

    pub(super) fn set_auto_updates_impl(enabled: bool, logger: &dyn LogSink) -> Result<()> {
        let args = build_defaults_args(enabled);
        let output = Command::new("defaults")
            .args(&args)
            .output()
            .map_err(|error| CoreError::Message(format!("执行 defaults 命令失败: {error}")))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(CoreError::Message(format!(
                "defaults write 失败（退出码 {}）: {}",
                output.status,
                stderr.trim()
            )));
        }
        logger.info(format!(
            "已通过 defaults 写入 {} = {}",
            VALUE_KEY,
            !enabled
        ));
        Ok(())
    }

    pub(super) fn auto_updates_enabled_impl() -> Option<bool> {
        let output = Command::new("defaults")
            .args(["read", PREF_DOMAIN, VALUE_KEY])
            .output()
            .ok()?;
        if !output.status.success() {
            // defaults read 失败 → 键不存在或域不存在 → 未设置
            return None;
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        parse_defaults_output(&stdout)
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
mod platform {
    use claude_zh_core::{LogSink, LogSinkExt, Result};

    pub(super) fn set_auto_updates_impl(_enabled: bool, logger: &dyn LogSink) -> Result<()> {
        logger.warn("当前平台不支持自动更新策略写入，已忽略。");
        Ok(())
    }

    pub(super) fn auto_updates_enabled_impl() -> Option<bool> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use claude_zh_core::NoopLogger;

    /// 本机集成测试：会真实写入当前用户的注册表/偏好文件，所以默认 ignore。
    /// 跑法：cargo test -p claude-zh-platform --target x86_64-pc-windows-msvc -- --ignored auto_update
    /// 跑完会把状态恢复到「未设置」附近（设回 enabled=true）。
    #[test]
    #[ignore]
    fn roundtrip_disable_then_enable() {
        let logger = NoopLogger;
        // 禁用 → 读回应为 Some(false)
        set_auto_updates(false, &logger).expect("set false");
        assert_eq!(auto_updates_enabled(), Some(false));
        // 启用 → 读回应为 Some(true)
        set_auto_updates(true, &logger).expect("set true");
        assert_eq!(auto_updates_enabled(), Some(true));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn set_auto_updates_invokes_defaults_command() {
        // 验证 build_defaults_args 拼出来的参数正确
        let args = platform::build_defaults_args(false);
        assert_eq!(
            args,
            vec![
                "write",
                "com.anthropic.claudefordesktop",
                "disableAutoUpdates",
                "-bool",
                "true"
            ]
        );
        let args = platform::build_defaults_args(true);
        assert_eq!(
            args,
            vec![
                "write",
                "com.anthropic.claudefordesktop",
                "disableAutoUpdates",
                "-bool",
                "false"
            ]
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn auto_updates_enabled_parses_defaults_output() {
        // disableAutoUpdates=1 → 自动更新禁用 → Some(false)
        assert_eq!(platform::parse_defaults_output("1\n"), Some(false));
        // disableAutoUpdates=0 → 自动更新启用 → Some(true)
        assert_eq!(platform::parse_defaults_output("0\n"), Some(true));
        // 空输出 → 未设置
        assert_eq!(platform::parse_defaults_output(""), None);
        // 无法解析的内容
        assert_eq!(platform::parse_defaults_output("garbage"), None);
        // true/false/yes/no 兼容（大小写不敏感）
        assert_eq!(platform::parse_defaults_output("true\n"), Some(false));
        assert_eq!(platform::parse_defaults_output("FALSE"), Some(true));
        assert_eq!(platform::parse_defaults_output("Yes"), Some(false));
    }

    #[test]
    fn run_cli_request_set_auto_updates_requires_enabled() {
        use claude_zh_core::CliRequest;
        let request = CliRequest {
            action: "set_auto_updates".to_string(),
            install: None,
            restore: None,
            enabled: None,
            resources_path: None,
            log_path: None,
        };
        let logger = NoopLogger;
        let result = crate::elevation::run_cli_request(request, &logger);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("缺少 enabled"),
            "错误信息应包含 '缺少 enabled'，实际: {msg}"
        );
    }

    #[test]
    fn parse_enabled_flag_true() {
        let args: Vec<String> = ["--enabled", "true"].iter().map(|s| s.to_string()).collect();
        assert_eq!(parse_enabled_flag(&args), Ok(Some(true)));
    }

    #[test]
    fn parse_enabled_flag_equals_false() {
        let args: Vec<String> = ["--enabled=false"].iter().map(|s| s.to_string()).collect();
        assert_eq!(parse_enabled_flag(&args), Ok(Some(false)));
    }

    #[test]
    fn parse_enabled_flag_missing() {
        let args: Vec<String> = ["--other"].iter().map(|s| s.to_string()).collect();
        assert_eq!(parse_enabled_flag(&args), Ok(None));
    }

    #[test]
    fn parse_enabled_flag_duplicate() {
        let args: Vec<String> = ["--enabled", "true", "--enabled", "false"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert!(parse_enabled_flag(&args).is_err());
        assert!(parse_enabled_flag(&args).unwrap_err().contains("重复"));
    }

    #[test]
    fn parse_enabled_flag_invalid_value() {
        let args: Vec<String> = ["--enabled", "yes"].iter().map(|s| s.to_string()).collect();
        assert!(parse_enabled_flag(&args).is_err());
        assert!(parse_enabled_flag(&args).unwrap_err().contains("无效值"));
    }
}
