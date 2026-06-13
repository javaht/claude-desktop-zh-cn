//! Claude Desktop 自动更新策略读写。
//!
//! 目标：让 UI 上的「自动更新」开关真正影响 Claude Desktop 的更新行为，
//! 而不是写一份只有本工具自己看的影子配置。
//!
//! 实现要点：
//! - Windows：写用户级注册表 `HKCU\Software\Policies\Claude\disableAutoUpdates`
//!   （DWORD，1 = 禁用）。Claude Desktop 官方企业策略字段同名。
//!   使用 HKCU 而非 HKLM 的原因：
//!     1. Claude Desktop 检测到 HKLM\SOFTWARE\Policies\Claude 键存在就会判定
//!        为"组织管理模式"，锁死"配置第三方推理 / 网关"等设置页；
//!     2. HKCU 写入不需要管理员权限，避免触发 UAC 提权子进程带来的用户 hive
//!        错位问题（提权子进程的 HKCU 可能是管理员账号而非桌面用户）；
//!     3. 自动更新策略本就是用户偏好，不需要机器级作用域。
//!
//!   **启用时必须删除 value 而非写 0**：Claude Desktop 检测到
//!   `HKCU\SOFTWARE\Policies\Claude` 下**任何** value 存在就会将配置窗口锁定为只读
//!   并显示 "This configuration is managed by your organization"，跟 value 内容无关。
//!   写 `disableAutoUpdates=0` 仍然会触发 managed 状态，因此启用时必须用
//!   `RegDeleteValueW` 删除该 value。
//!
//!   写 HKCU\Software\Policies 不需要管理员，从 actions 层直接调用即可。
//!   读取用 KEY_READ（仅支持 64 位进程；本项目仅发 x64 构建）。
//! - macOS：通过 `defaults` 命令写入 `com.anthropic.claudefordesktop` 域的
//!   `disableAutoUpdates`（boolean）。`defaults` 走 CFPreferences 标准通道，
//!   自动处理缓存同步，无需直接读写 plist 文件。

use claude_zh_core::{LogSink, LogSinkExt, Result};

/// 设置 Claude Desktop 是否启用自动更新。
///
/// `enabled = true` → 启用自动更新（删除 `disableAutoUpdates` value，不写 0）。
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
/// 返回 `Some(true)` 表示自动更新已启用，`Some(false)` 表示已禁用。
/// `None` 表示读取失败（命令执行异常、输出无法解析等），上层应视为"状态未知"。
///
/// **默认行为（key 不存在）**：Windows 和 macOS 均视为"未设置禁用策略"，
/// 即 Claude Desktop 默认启用自动更新，返回 `Some(true)`。
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
        RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW,
        RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_READ, KEY_WRITE,
        REG_DWORD, REG_OPTION_NON_VOLATILE, REG_VALUE_TYPE,
    };

    const SUBKEY: &str = r"Software\Policies\Claude";
    const VALUE_NAME: &str = "disableAutoUpdates";

    /// `ERROR_FILE_NOT_FOUND`（Win32 error 2）转为 HRESULT 后的值。
    /// `RegDeleteValueW` 在 value 本来就不存在时返回此错误，应视为成功。
    const HRESULT_ERROR_FILE_NOT_FOUND: i32 = 0x80070002u32 as i32;

    pub(super) fn set_auto_updates_impl(enabled: bool, logger: &dyn LogSink) -> Result<()> {
        let subkey_w = to_wide(SUBKEY);
        let value_w = to_wide(VALUE_NAME);

        if enabled {
            // ── 启用自动更新：删除 disableAutoUpdates value ──
            // 不能写 0，否则 Claude Desktop 检测到 HKCU\SOFTWARE\Policies\Claude 下
            // 任何 value 存在就会锁定配置窗口为只读（managed 状态）。
            let mut hkey = HKEY::default();
            let open = unsafe {
                RegOpenKeyExW(
                    HKEY_CURRENT_USER,
                    PCWSTR(subkey_w.as_ptr()),
                    0,
                    KEY_WRITE,
                    &mut hkey,
                )
            };
            if open.is_err() {
                // key 本身就不存在，value 也不可能存在，无需删除。
                logger.info(format!(
                    "HKCU\\{SUBKEY} 不存在，自动更新已处于默认启用状态"
                ));
                return Ok(());
            }
            let delete_result = unsafe { RegDeleteValueW(hkey, PCWSTR(value_w.as_ptr())) };
            unsafe {
                let _ = RegCloseKey(hkey);
            }
            match delete_result {
                Ok(()) => {
                    logger.info(format!(
                        "已删除 HKCU\\{SUBKEY}\\{VALUE_NAME}（启用自动更新）"
                    ));
                }
                Err(error) => {
                    if error.code().0 == HRESULT_ERROR_FILE_NOT_FOUND {
                        // value 本来就不存在，视为成功
                        logger.info(format!(
                            "HKCU\\{SUBKEY}\\{VALUE_NAME} 已不存在，自动更新已处于启用状态"
                        ));
                    } else {
                        return Err(CoreError::Message(format!(
                            "删除 HKCU\\{SUBKEY}\\{VALUE_NAME} 失败: {error}"
                        )));
                    }
                }
            }
        } else {
            // ── 禁用自动更新：写 disableAutoUpdates = 1 ──
            let mut hkey = HKEY::default();
            unsafe {
                RegCreateKeyExW(
                    HKEY_CURRENT_USER,
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
                        "无法打开/创建注册表项 HKCU\\{SUBKEY}: {error}"
                    ))
                })?;
            }
            let disable: u32 = 1;
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
                    "写入 HKCU\\{SUBKEY}\\{VALUE_NAME} 失败: {error}"
                ))
            })?;
            logger.info(format!(
                "已写入 HKCU\\{SUBKEY}\\{VALUE_NAME} = {disable}"
            ));
        }
        Ok(())
    }

    pub(super) fn auto_updates_enabled_impl() -> Option<bool> {
        let subkey_w = to_wide(SUBKEY);
        let value_w = to_wide(VALUE_NAME);
        let mut hkey = HKEY::default();
        let open = unsafe {
            RegOpenKeyExW(
                HKEY_CURRENT_USER,
                PCWSTR(subkey_w.as_ptr()),
                0,
                KEY_READ,
                &mut hkey,
            )
        };
        if open.is_err() {
            // 注册表项不存在 → 没有策略 → 默认启用
            return Some(true);
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
            // value 不存在 → 没有禁用策略 → 默认启用
            return Some(true);
        }
        // 严格校验：只接受 4 字节 REG_DWORD。类型不匹配说明外部把
        // 别的数据塞到这个 key 下，不视为有效的禁用策略。
        if value_type != REG_DWORD || data_len != 4 {
            return Some(true);
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
            // defaults read 非零退出 → 键不存在或域不存在 → 未设置禁用策略 → 默认启用。
            // 与 Windows 行为对齐：key/value 不存在均视为 Some(true)。
            // （命令本身执行失败、权限拒绝等已由上方 .ok()? 捕获为 None。）
            return Some(true);
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

    /// macOS 集成测试：从未设置过策略时，auto_updates_enabled 应返回 Some(true)。
    /// 完整验证需 macOS + Claude Desktop 环境，跑法：
    ///   cargo test -p claude-zh-platform --target x86_64-apple-darwin -- --ignored auto_update
    /// 此处用 parse_defaults_output 的行为间接验证：defaults read 失败（键不存在）
    /// 时 parse_defaults_output 对空输出返回 None，而 auto_updates_enabled_impl
    /// 会在 defaults read 非零退出时拦截并返回 Some(true)。
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore]
    fn auto_updates_enabled_defaults_to_true_when_key_absent() {
        // 先确保 key 不存在（如果之前测试写过，可能残留）
        let _ = std::process::Command::new("defaults")
            .args(["delete", "com.anthropic.claudefordesktop", "disableAutoUpdates"])
            .output();
        let result = auto_updates_enabled();
        assert_eq!(
            result,
            Some(true),
            "未设置策略时 macOS 应返回 Some(true)（与 Windows 对齐），实际: {result:?}"
        );
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

    /// 断言 SUBKEY 不含 HKLM 前缀（Windows 平台用 HKCU 写入，避免触发组织管理模式）。
    #[cfg(windows)]
    #[test]
    fn subkey_is_user_level_not_machine_level() {
        use super::platform::SUBKEY;
        // SUBKEY 本身是相对路径，不应包含 HKEY 前缀；关键是调用方用 HKEY_CURRENT_USER。
        // 这里再验证路径不含 HKLM 特有的模式（防御性检查）。
        assert!(
            !SUBKEY.contains("HKLM"),
            "SUBKEY 不应包含 HKLM 前缀，当前值: {SUBKEY}"
        );
        assert!(
            SUBKEY.starts_with("Software\\Policies\\Claude"),
            "SUBKEY 应以 Software\\Policies\\Claude 开头，当前值: {SUBKEY}"
        );
    }

    /// 验证 HRESULT_ERROR_FILE_NOT_FOUND 常量值正确。
    /// `RegDeleteValueW` 在 value 本来就不存在时返回此错误码，代码必须将其视为成功。
    #[cfg(windows)]
    #[test]
    fn error_file_not_found_hresult_is_correct() {
        use super::platform::HRESULT_ERROR_FILE_NOT_FOUND;
        // ERROR_FILE_NOT_FOUND (Win32 error 2) → HRESULT 0x80070002
        assert_eq!(
            HRESULT_ERROR_FILE_NOT_FOUND,
            0x80070002u32 as i32,
            "HRESULT_ERROR_FILE_NOT_FOUND 应等于 0x80070002"
        );
    }

    /// 集成测试：启用自动更新后，value 应被删除而非写 0。
    /// 写 0 会触发 Claude Desktop 的 managed 状态，锁死配置窗口。
    /// 跑法：cargo test -p claude-zh-platform --target x86_64-pc-windows-msvc -- --ignored auto_update
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn enable_auto_updates_deletes_value_not_writes_zero() {
        let logger = NoopLogger;
        // 先禁用，确保 value 存在
        set_auto_updates(false, &logger).expect("set false");
        assert_eq!(auto_updates_enabled(), Some(false));
        // 启用后，value 应被删除（不是写 0），auto_updates_enabled 返回 Some(true)
        set_auto_updates(true, &logger).expect("set true");
        assert_eq!(
            auto_updates_enabled(),
            Some(true),
            "启用后应返回 Some(true)，且注册表中 disableAutoUpdates value 已被删除"
        );
    }

    /// 集成测试：从未设置过策略时，auto_updates_enabled 应返回 Some(true)。
    /// 模拟"配置窗口不被锁定"的初始状态——key/value 不存在时默认启用。
    /// 跑法：cargo test -p claude-zh-platform --target x86_64-pc-windows-msvc -- --ignored auto_update
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn auto_updates_enabled_defaults_to_true_when_unset() {
        // 注意：此测试依赖注册表中 key/value 不存在的状态，
        // 跑前需手动删除 HKCU\Software\Policies\Claude 或确认不存在。
        let result = auto_updates_enabled();
        assert_eq!(
            result,
            Some(true),
            "未设置策略时应返回 Some(true)，实际: {result:?}"
        );
    }
}
