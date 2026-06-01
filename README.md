# Claude Desktop 中文补丁

一个用于 Claude Desktop 的中文界面汉化补丁，支持简体中文、繁体中文（中国台湾）和繁体中文（中国香港）。

macOS 可双击 `install-mac.command`，Windows 可右键管理员运行 `install-windows.bat`，给 Claude Desktop 添加中文语言选项，并安装中文界面资源。

本汉化方案支持使用 API 和官方订阅的方式。第三方api请先参照 https://linux.do/t/topic/2032192 配置。


**遇到问题请及时反馈，欢迎扫码加入 claude desktop 交流。**

<img src="docs/images/wechat-group.png" alt="claude desktop 交流群二维码" width="360">

## 界面截图

![Claude Desktop 中文界面截图](docs/images/claude-desktop-zh-cn-home.png) ![Claude Desktop 中文设置界面截图](docs/images/claude-desktop-zh-cn-settings.png)

<div align="center">



</div>

## 功能特点

- 一键安装 Claude Desktop 中文界面资源，支持 macOS 和 Windows。
- 支持三种中文变体：`zh-CN`（简体中文）、`zh-TW`（繁体中文（中国台湾））、`zh-HK`（繁体中文（中国香港））。
- 自动给 Claude 前端语言白名单加入当前选择的中文变体。
- 会修改 `app.asar` 的安装模式可对在线账号登录后的 `claude.ai` 页面做显示层 DOM 翻译；该逻辑只改界面文本和语言状态，不改第三方 API、网关、模型路由或请求内容。
- macOS 自动合并当前 Claude 版本的英文语言文件与随包中文翻译。
- 新版本新增但暂未翻译的字段会保留英文，避免界面缺失文本。
- macOS 可绕过新版 Claude Desktop 对 3P gateway 模型名的本地 Anthropic 校验，避免 `deepseek-v4-pro` / `kimi-*` 等模型名导致配置整体失效。
- Windows 安装脚本会直接备份并修改当前 Claude Desktop 的资源文件；卸载时从备份恢复。注意：修改 `app.asar` 后需要同步改写 `Claude.exe` 内嵌完整性哈希，这会破坏 Authenticode 签名；Cowork 沙箱/截图工作区需要签名验证，建议需要 Cowork 时选择 Windows 模式 1，并在网关或 ccswitch 中做模型别名映射。
- macOS 安装前自动备份原始 `/Applications/Claude.app`。
- 自动写入 Claude 用户配置，将语言设置为所选中文变体。

## 适用环境

- macOS 或 Windows
- 已安装 Claude Desktop
- macOS 需要系统自带 Python 3（通常路径为 `/usr/bin/python3`）
- Windows 需要 PowerShell，并建议以管理员权限运行

## 使用方式

### macOS

1. 退出 Claude Desktop。
2. 下载或克隆本项目。
3. 双击 `install-mac.command`，选择安装中文补丁、安全模式安装或恢复原样 / 卸载补丁。
4. 安装时选择要安装的语言（1=简体中文，2=繁体中文（中国台湾），3=繁体中文（中国香港））。安全模式同样支持三种中文，并跳过结构性 `app.asar` 补丁；仅保留等长菜单汉化补丁。
5. 按提示输入 Mac 登录密码。
6. Claude 会自动重新打开。
7. 如果没有自动切换，打开左下角账号菜单，选择 `Language` -> 对应的中文选项。

### Windows

1. 退出 Claude Desktop。
2. 下载或克隆本项目。
3. 右键 `install-windows.bat`，选择以管理员身份运行。
4. 先选择安装模式：
   - `1` 安装中文补丁（Cowork 兼容模式，跳过 `app.asar` 补丁；第三方模型请用网关或 ccswitch 别名映射）
   - `2` 安装中文补丁（官方账号登录模式：仅启用 Claude.ai 登录 / 在线页面汉化，不修改第三方模型名校验）
   - `3` 安装中文补丁（第三方 API 实验模式：包含模式 2，并去除 3P 模型名限制；Cowork 沙箱/截图工作区可能不可用）
   - `4` 恢复原样 / 卸载补丁
5. 安装时再选择语言：
   - `1` 简体中文
   - `2` 繁体中文（中国台湾）
   - `3` 繁体中文（中国香港）
6. 脚本会备份当前 Claude Desktop 资源，写入本仓库 `resources` 目录里的中文 JSON，补齐硬编码界面文本，并重启 Claude Desktop。选择模式 1 时会跳过 `app.asar` 补丁，更适合需要 Cowork/截图工作区的场景。选择模式 2 或 3 时会直接修改当前 Claude 的 `app.asar`，卸载时从备份恢复。
7. 如果没有自动切换，打开左下角账号菜单，选择 `Language` -> 对应的中文选项。


## 文件说明

- `install-mac.command`：macOS 双击运行入口。
- `install-windows.bat`：Windows 安装 / 恢复菜单入口。
- `scripts/install_windows.ps1`：Windows 汉化安装和卸载脚本。
- `scripts/patch_claude_zh_cn.py`：真正执行补丁的 Python 脚本。
- `resources/manifest.json` / `manifest-zh-TW.json` / `manifest-zh-HK.json`：语言包信息。
- `resources/frontend-zh-CN.json` / `frontend-zh-TW.json` / `frontend-zh-HK.json`：Claude 前端界面中文翻译。
- `resources/desktop-zh-CN.json` / `desktop-zh-TW.json` / `desktop-zh-HK.json`：Claude 桌面壳层中文翻译。
- `resources/Localizable.strings` / `Localizable-zh-TW.strings` / `Localizable-zh-HK.strings`：macOS 原生菜单中文资源。
- `resources/statsig-zh-CN.json` / `statsig-zh-TW.json` / `statsig-zh-HK.json`：statsig i18n 兜底资源。

## macOS 脚本会做什么

- 安装时备份当前 `/Applications/Claude.app` 到同目录，名字类似：
  `Claude.backup-before-zh-CN-20260424-120000.app`
- 恢复 / 卸载时选择同目录下最早的 `Claude.backup-before-zh-CN-*.app` 恢复为 `/Applications/Claude.app`，并删除其他备份。
- 复制 Claude.app 到临时目录并打补丁。
- 给前端语言白名单加入当前选择的中文变体。
- 对 `Contents/Resources/app.asar` 做等长补丁，关闭 3P gateway 启动阶段的 `inferenceModels` Anthropic 名称校验；安全模式会跳过这一步。
- 安全模式仍会对主进程菜单中的硬编码英文做等长汉化补丁，覆盖开发者菜单等少量不走资源文件的菜单项。
- 普通安装模式会在在线账号登录 / 聊天页面注入显示层 DOM 翻译，覆盖聊天、项目、Artifacts 等远程页面；安全模式会跳过此项，因为它需要修改 `app.asar`。
- 合并当前 Claude 版本的 `en-US.json` 和随包中文翻译：
  当前版本已有中文翻译的 key 会变中文，新版本新增但本包没有的 key 会保留英文，避免应用缺字段。
- 写入 `~/Library/Application Support/Claude/config.json`，设置 `"locale"` 为所选语言代码（`zh-CN`、`zh-TW` 或 `zh-HK`），并在 `claude.ai` 页面加载前同步其前端语言状态。
- 对修改后的 Claude.app 及其内部 app/framework/原生二进制做一致的本机 ad-hoc 重签名，并清除 `com.apple.quarantine` 隔离属性。
- 重新启动 Claude。

## Windows 脚本会做什么

- 查找 Windows 版 Claude Desktop 安装目录。
- 修改前备份将被改动的前端 JS bundle、`app.asar` 和 `Claude.exe` 到 `resources\.zh-cn-backups`。
- 复制本仓库现有中文资源，不使用其他语言包项目里的 JSON：
  - `resources/frontend-zh-CN.json` / `frontend-zh-TW.json` / `frontend-zh-HK.json` -> `ion-dist\i18n\` 对应语言代码 `.json`
  - `resources/desktop-zh-CN.json` / `desktop-zh-TW.json` / `desktop-zh-HK.json` -> `resources\` 对应语言代码 `.json`
  - `resources/statsig-zh-CN.json` / `statsig-zh-TW.json` / `statsig-zh-HK.json` -> `ion-dist\i18n\statsig\` 对应语言代码 `.json`
- 给前端语言白名单加入当前选择的中文变体。
- 汉化前端 bundle 中未走 i18n JSON 的硬编码界面文本，例如侧边栏入口、配置页标签和模型选择项。
- 官方账号登录模式和第三方 API 实验模式会在在线账号登录 / 聊天页面注入显示层 DOM 翻译，覆盖聊天、项目、Artifacts 等远程页面；Cowork 兼容模式会跳过此项，因为它需要修改 `app.asar`。
- 第三方 API 实验模式会对 unpackaged 版本的 `resources\app.asar` 做等长补丁，关闭 3P gateway 启动阶段的 `inferenceModels` Anthropic 名称校验，并同步更新 asar 内部文件完整性信息和 `Claude.exe` 内嵌的 asar header hash。
- Windows 的模式 2 和 3 会直接改写当前 Claude 的 `app.asar` 并同步改写 `Claude.exe` 内嵌完整性哈希，导致 Authenticode 签名 `HashMismatch`；Cowork VM 服务可能拒绝客户端并报 `RPC pipe closed`。如果需要 Cowork 沙箱/截图工作区，请使用模式 1，并通过网关/ccswitch 模型别名映射解决第三方模型名校验。
- 写入 Windows 用户配置，将语言设置为所选语言代码（`zh-CN`、`zh-TW` 或 `zh-HK`）。
- 重启 Claude Desktop。

## 卸载 / 恢复

执行脚本，选择恢复即可。

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=javaht/claude-desktop-zh-cn&type=Date)](https://www.star-history.com/#javaht/claude-desktop-zh-cn&Date)

## 免责声明

本项目为非官方中文补丁，仅修改本机 Claude Desktop 的本地资源文件。Claude Desktop 更新后资源结构可能变化，若补丁失败，请先更新本项目或重新运行安装脚本。
