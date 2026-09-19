# Claude Desktop 中文补丁

一个用于 Claude Desktop 的本地中文界面补丁，支持简体中文、繁体中文（中国台湾）和繁体中文（中国香港）。

macOS 双击 `install-mac.command`；Windows 双击 `install-windows.bat` 后按 UAC 提示授权；Linux（deb 包安装）在终端运行 `./install-linux.sh`。脚本会给 Claude Desktop 添加中文语言选项并安装中文界面资源。

本项目支持官方账号和第三方 API，但不同安装模式覆盖的界面与 Cowork 兼容性不同，请先阅读下方的模式说明。第三方 API 配置可参考 [这篇教程](https://linux.do/t/topic/2032192)。

## 赞助商

<details open>
<summary>点击折叠</summary>
<table width="100%">
<tr>
<td width="250" align="center" valign="middle"><a href="https://tokenmetro.com"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tokenmetro-dark.png"><img src="docs/images/tokenmetro-light.png" alt="TokenMetro" width="216"></picture></a></td>
<td valign="middle"><strong>TokenMetro</strong> - 一家计费透明、自建号池的中转站。<br>
相对官方价格：GPT 1 折，Gemini 一次 5分，DeepSeek0.1折。<br>
明码标价，显示多少扣多少，不玩汇率魔术；自建号池，拒绝掺水。<br>
限时福利 - 注册就送 5 ¥，一键上车：<a href="https://tokenmetro.com">https://tokenmetro.com</a></td>
</tr>
<tr>
<td width="250" align="center" valign="middle"><a href="https://www.oxoapi.com"><img src="docs/images/oxoapi.png" alt="OXOAPI" width="151"></a></td>
<td valign="middle"><strong>OXOAPI</strong> - 高质量国模自部署资源，AI 模型统一接口入口。热门国产模型 DeepSeek、Kimi、GLM 低至 4.5-6 折，海外模型低至 2.5 折；官网实时公开报价，价格自动刷新、通道状态透明可见；支持开具发票，企业采购更省心。注册即用：<a href="https://www.oxoapi.com">www.oxoapi.com</a>，完整价格表：<a href="https://www.oxoapi.com/pricing">www.oxoapi.com/pricing</a></td>
</tr>
</table>


</details>

**遇到问题请及时反馈，欢迎扫码加入 claude desktop 交流。**

<img src="docs/images/wechat-group.png" alt="claude desktop 交流群二维码" width="360">

## 界面截图

![Claude Desktop 中文界面截图](docs/images/claude-desktop-zh-cn-home.png) ![Claude Desktop 中文设置界面截图](docs/images/claude-desktop-zh-cn-settings.png)

## 功能特点

- 一键安装 Claude Desktop 中文界面资源，支持 macOS、Windows 和 Linux（deb 包安装）。
- 支持三种中文变体：`zh-CN`（简体中文）、`zh-TW`（繁体中文（中国台湾））、`zh-HK`（繁体中文（中国香港））。
- 自动给 Claude 前端语言白名单加入当前选择的中文变体。
- 完整/官方账号模式会修改 `app.asar`，对在线账号登录后的 `claude.ai` 页面做显示层 DOM 翻译；该逻辑只改界面文本和语言状态，不改第三方 API、网关、模型路由或请求内容。
- macOS 和 Linux 会合并当前 Claude 版本的英文语言文件与随包中文翻译；新版本新增但暂未翻译的字段保留英文，避免界面缺失文本。
- macOS 完整补丁模式可绕过新版 Claude Desktop 对第三方网关模型名的本地 Anthropic 校验，避免 `deepseek-v4-pro` / `kimi-*` 等模型名导致配置整体失效；跳过结构性 `app.asar` 的模式不包含此功能。
- Windows 安装脚本会备份并修改当前 Claude Desktop 的资源文件，卸载时从备份恢复。需要 Cowork 沙箱或截图工作区时应选择 Windows 模式 1。
- Linux 安装脚本会备份并修改 deb 包安装目录下的资源文件和 `app.asar`，卸载时从备份恢复；Claude Desktop 升级后会识别版本变化并重新备份。
- macOS 安装前自动备份原始 `/Applications/Claude.app`。
- 自动写入 Claude 用户配置，将语言设置为所选中文变体。

## 适用环境

- macOS、Windows 或 Linux（deb 包安装）
- 已安装 Claude Desktop
- macOS 需要可用的 Python 3；脚本优先使用 `/usr/bin/python3`，不存在时从 `PATH` 查找 `python3`
- Windows 需要系统自带的 Windows PowerShell（`powershell.exe`）；批处理入口会自动请求管理员权限
- Linux 需要 Python 3 和 `sudo` 权限，且为官方 deb 包安装的 Claude Desktop（资源目录 `/usr/lib/claude-desktop/resources`，可用环境变量 `CLAUDE_RESOURCES` 覆盖）

## 使用方式

### macOS

1. 退出 Claude Desktop。
2. 下载或克隆本项目。
3. 双击 `install-mac.command`，选择操作：
   - `1` 完整补丁：支持官方账号和第三方 API；会修改 `app.asar`，包含在线页面 DOM 汉化、在线语言锁定、第三方模型名校验绕过和 `app.asar` 内模型选择器汉化。此模式不适合依赖 Cowork 沙箱/工作区的场景。
   - `2` 跳过结构性 `app.asar` 补丁：仍会安装中文资源、注册中文语言、汉化前端 bundle，并对少量主进程菜单做等长替换；不会注入在线页面 DOM 汉化，不会绕过第三方模型名校验，也不会修改 `app.asar` 内模型选择器。此模式仍会对应用做本机 ad-hoc 重签名，不承诺 Cowork 可用。
   - `3` Frida 运行时汉化启动（实验）：**不写**磁盘 `app.asar`、**不复制**官方包到其他路径；用 Frida 内存补丁 + CDP 注入。在 SIP 仍开启时，会**就地**对 `/Applications/Claude.app` 做 ad-hoc 重签名（加 `get-task-allow`、去掉 Hardened Runtime），否则 Frida 无法 attach。账号模式跟随客户端原有配置。需要本机允许写入 `/Applications/Claude.app` 的签名，**不能**当普通用户的通用安装方式。
   - `4` 恢复原样 / 卸载补丁。
   - `5` 自动更新设置：输入 `y` 禁止自动更新，输入 `n` 允许自动更新。
   - `6` CC Switch skills 同步：输入 `y` 同步，输入 `n` 删除之前的同步。
4. 选择安装后，脚本会先恢复已有旧备份以清理上一轮补丁；没有旧备份时会直接继续。
5. 选择语言：`1`=简体中文，`2`=繁体中文（中国台湾），`3`=繁体中文（中国香港）。
6. 按提示输入 Mac 登录密码（选项 `1`/`2`/`4`/`5`）。安装完成后 Claude 会自动重新打开。
7. 如果没有自动切换，打开左下角账号菜单，选择 `Language` -> 对应的中文选项。

CC Switch skills 同步会扫描 `~/.cc-switch/skills` 下包含 `SKILL.md` 的目录，只为 Claude Desktop 中不存在的同名 skill 创建软链接并更新 skills manifest。取消同步只删除由该目录同步出的软链接和对应记录，不删除 CC Switch 源目录。

### macOS 汉化后的自动更新

汉化会对应用做本机 ad-hoc 重签名。从 2026-08 版本起，重签时会显式写入 `identifier` 级别的 designated requirement（替代默认的 cdhash 级别），因此 Claude Desktop 的官方自动更新**下载后可以正常安装**，不会再卡在“下载完成但版本不变”。注意两点：

- 更新安装成功后，`/Applications/Claude.app` 会被官方英文版覆盖，重新运行本补丁即可恢复中文。
- 如果之前打过旧版补丁（默认 ad-hoc DR），需重新打一次补丁才会获得新签名行为。

### Windows

1. 退出 Claude Desktop。
2. 下载或克隆本项目。
3. 双击 `install-windows.bat`；脚本会复制安装文件到当前用户的临时目录，并弹出 UAC 管理员授权窗口。
4. 先选择安装模式：
   - `1` Cowork 兼容 / 第三方 API 模式：跳过 `app.asar` 和 `Claude.exe` 内嵌完整性哈希修改；仍会安装中文资源、注册中文语言并汉化前端 bundle。在线账号页面中依赖 DOM 注入的文本不会被覆盖，第三方模型需在网关或 CC Switch 中映射为 Claude/Anthropic 风格名称。
   - `2` 官方账号在线汉化模式：修改 `app.asar` 并同步改写 `Claude.exe` 内嵌完整性哈希，补充在线页面 DOM、主进程菜单和模型选择器汉化。该操作会使 `Claude.exe` 的 Authenticode 签名变为 `HashMismatch`，Cowork 沙箱/工作区可能拒绝启动。
   - `3` Frida 运行时汉化（实验）：**不修改**磁盘上的 `app.asar` / `Claude.exe`；用 Frida 内存补丁 + CDP 注入在线页 DOM 中文。若本机没有 Python+frida，会提示下载便携运行时到 `%LOCALAPPDATA%\claude-zh\runtime`（仅本工具使用，不改系统 Python）。可选注册/卸载用户登录常驻；卸载常驻时可选择同时删除便携运行时。需要本机允许 Frida 注入，**不能**当普通用户的通用安装方式。
   - 在模式 `1`/`2` 与模式 `3` 之间切换时，安装器会先停用旧的 Frida 常驻任务，避免常驻 watcher 接管并重启磁盘补丁模式的 Claude；便携运行时会保留，之后重新选择模式 `3` 会刷新并复用。
   - `4` 恢复原样 / 卸载补丁。
   - `5` 自动更新设置：输入 `y` 禁止自动更新，输入 `n` 允许自动更新。
   - `6` CC Switch skills 同步：输入 `y` 开启同步，输入 `n` 删除之前的同步。
5. 选择安装中文补丁时，脚本会先尝试从旧备份恢复来清理已有汉化；如果没有旧备份，会提示跳过并继续。
6. 选择语言：`1`=简体中文，`2`=繁体中文（中国台湾），`3`=繁体中文（中国香港）。
7. 脚本会备份被修改的文件、写入中文资源并重启 Claude Desktop。如果没有自动切换，打开左下角账号菜单，选择 `Language` -> 对应的中文选项。

### Linux（deb 包安装）

1. 退出 Claude Desktop（脚本检测到正在运行时也会自动关闭）。
2. 下载或克隆本项目。
3. 在项目目录中打开终端，运行 `./install-linux.sh`，选择操作：
   - `1` 安装中文补丁：安装中文资源、注册中文语言，并修改 `app.asar`，包含在线页面 DOM 汉化和在线语言锁定。
   - `2` 恢复原样 / 卸载补丁。
4. 选择语言：`1`=简体中文，`2`=繁体中文（中国台湾），`3`=繁体中文（中国香港）。
5. 按提示输入 `sudo` 密码。完成后重新打开 Claude Desktop；如果没有自动切换，打开左下角账号菜单，选择 `Language` -> 对应的中文选项。

也可以跳过菜单直接调用：`./install-linux.sh install zh-CN`（可选 `zh-TW` / `zh-HK`）或 `./install-linux.sh uninstall`。

### Linux 升级后恢复

通过 apt 升级 Claude Desktop 会覆盖补丁，界面会变回英文。建议先更新本项目（克隆的用 `git pull`，下载压缩包的重新下载最新版本），再重新运行一次安装：

```bash
git pull
./install-linux.sh install zh-CN
```

脚本会识别 Claude Desktop 的版本变化，自动丢弃旧版本的备份并重新备份，不会把旧版 `app.asar` 装回去。若新版本改动了代码结构导致补丁没有生效，脚本会直接报错，请带上 Claude Desktop 版本号反馈。

## 文件说明

- `install-mac.command`：macOS 双击运行入口。
- `install-windows.bat`：Windows 安装 / 恢复菜单入口。
- `install-linux.sh`：Linux（deb 包）安装 / 恢复菜单入口。
- `scripts/install_windows.ps1`：Windows 汉化安装和卸载脚本。
- `scripts/install_linux.sh`：Linux（deb 包）汉化安装和卸载脚本；`install-linux.sh` 的菜单会调用它，也可直接带参数调用。
- `scripts/patch_linux_asar.py`：Linux 下复用 `patch_claude_zh_cn.py` 的 asar 补丁逻辑（伪造 macOS 目录布局 + 跳过 codesign/完整性），并在补丁后校验标记防止静默失败。
- `scripts/patch_claude_zh_cn.py`：真正执行补丁的 Python 脚本。
- `install-mac.command` 选项 `3` / `scripts/experimental/frida_launch_zh.py`：macOS Frida 实验启动入口（自动 venv + 依赖）。
- `scripts/experimental/run_frida_zh_win.ps1` / `bootstrap_frida_runtime_win.ps1` / `frida_launch_zh_win.py` / `frida_cdp_gate_win.js` / `frida-zh-resident-ctl.ps1`：Windows Frida 实验入口、便携 Python 自举、启动器、Agent 与常驻计划任务。
- `scripts/experimental/requirements-frida.txt` / `objc.js`：Frida 依赖清单与 macOS ObjC bridge 兜底文件。
- `resources/manifest.json` / `manifest-zh-TW.json` / `manifest-zh-HK.json`：语言包信息。
- `resources/frontend-zh-CN.json` / `frontend-zh-TW.json` / `frontend-zh-HK.json`：Claude 前端界面中文翻译。
- `resources/frontend-hardcoded-zh-CN.json` / `frontend-hardcoded-zh-TW.json` / `frontend-hardcoded-zh-HK.json`：未走 i18n key 的前端硬编码文本映射，也用于在线账号页面的 DOM 翻译表。
- `resources/desktop-zh-CN.json` / `desktop-zh-TW.json` / `desktop-zh-HK.json`：Claude 桌面壳层中文翻译。
- `resources/Localizable.strings` / `Localizable-zh-TW.strings` / `Localizable-zh-HK.strings`：macOS 原生菜单中文资源。
- `resources/statsig-zh-CN.json` / `statsig-zh-TW.json` / `statsig-zh-HK.json`：statsig i18n 兜底资源。
- `resources/release.json`：安装入口用于检查 GitHub Releases 是否有新版的版本信息。

## macOS 脚本会做什么

- 安装时备份当前 `/Applications/Claude.app` 到同目录，名字类似：
  `Claude.backup-before-zh-CN-20260424-120000.app`
- 安装前会先尝试恢复已有旧备份，清理上一轮汉化；没有旧备份时跳过并继续安装。
- 恢复 / 卸载时选择同目录下最早的 `Claude.backup-before-zh-CN-*.app` 恢复为 `/Applications/Claude.app`，并删除其他备份。
- 复制 Claude.app 到临时目录并打补丁。
- 给前端语言白名单加入当前选择的中文变体。
- 两种安装模式都会汉化前端 bundle 中未走 i18n key 的硬编码文本，并修正中文语言显示名称。
- 完整补丁模式会修改 `Contents/Resources/app.asar`：注入在线账号页面 DOM 翻译和语言锁定、汉化主进程菜单及模型选择器，并用等长替换关闭第三方网关模型名校验。
- 跳过结构性 `app.asar` 的模式不会执行上述结构性注入和模型校验绕过，但仍会对少量主进程菜单文本做保持字节长度的替换。
- 合并当前 Claude 版本的 `en-US.json` 和随包中文翻译：
  当前版本已有中文翻译的 key 会变中文，新版本新增但本包没有的 key 会保留英文，避免应用缺字段。
- 写入 `~/Library/Application Support/Claude/config.json`，设置 `"locale"` 为所选语言代码（`zh-CN`、`zh-TW` 或 `zh-HK`）。完整补丁模式还会在在线页面加载时同步并锁定前端语言状态。
- 对修改后的 Claude.app 及其内部 app/framework/原生二进制做一致的本机 ad-hoc 重签名，并清除 `com.apple.quarantine` 隔离属性。
- 重新启动 Claude。
- 可选菜单项 `3` 为 Frida 实验启动：不写 `app.asar`、不复制 app；依赖本机 Python 的 `frida`/`websockets`（可自动建 `.venv`）。在 SIP 开启时会自动对本机官方包做调试向 ad-hoc 重签以允许注入；失败时优先看签名/`csrutil status`，而不是补丁包损坏。
- 可选菜单项 `5` 用 `y/n` 控制 Claude Desktop 自动更新：`y` 禁止自动更新，`n` 允许自动更新。若当前存在有效的 Claude-3p `configLibrary`，脚本会写入当前 applied 配置；否则写入 Claude Desktop enterprise policy。
- 可选菜单项 `6` 用 `y/n` 控制 CC Switch skills 同步：`y` 会把 `~/.cc-switch/skills` 中缺失的 skill 软链接到 Claude Desktop 的本地 skills 目录，并更新对应 `manifest.json`；`n` 只删除之前同步产生的 CC Switch 软链接和对应 manifest 记录。该操作不需要管理员权限，不会覆盖同名 skill。

## Windows 脚本会做什么

- 查找 Windows 版 Claude Desktop 安装目录。
- 安装前会先尝试从 `resources\.zh-cn-backups` 恢复旧备份，清理上一轮汉化；没有旧备份时跳过并继续安装。
- 修改前只备份实际会改动的文件到 Claude 安装目录下的 `resources\.zh-cn-backups`；模式 1 不修改 `app.asar` 或 `Claude.exe`，模式 2 会备份并修改它们。
- 复制本仓库现有中文资源，不使用其他语言包项目里的 JSON：
  - `resources/frontend-zh-CN.json` / `frontend-zh-TW.json` / `frontend-zh-HK.json` -> `ion-dist\i18n\` 对应语言代码 `.json`
  - `resources/desktop-zh-CN.json` / `desktop-zh-TW.json` / `desktop-zh-HK.json` -> `resources\` 对应语言代码 `.json`
  - `resources/statsig-zh-CN.json` / `statsig-zh-TW.json` / `statsig-zh-HK.json` -> `ion-dist\i18n\statsig\` 对应语言代码 `.json`
- 给前端语言白名单加入当前选择的中文变体。
- 汉化前端 bundle 中未走 i18n JSON 的硬编码界面文本，例如侧边栏入口、配置页标签和模型选择项。
- 模式 2 会在在线账号登录 / 聊天页面注入显示层 DOM 翻译，覆盖聊天、项目、Artifacts 等远程页面；模式 1 会跳过此项，因为它需要修改 `app.asar`。
- Windows 的模式 2 会直接改写当前 Claude 的 `app.asar` 并同步改写 `Claude.exe` 内嵌完整性哈希，导致 Authenticode 签名 `HashMismatch`；Cowork VM 服务可能拒绝客户端并报 `RPC pipe closed`。如果需要 Cowork 沙箱/截图工作区，请使用模式 1，并通过网关或 CC Switch 模型别名映射解决第三方模型名校验。
- 写入 Windows 用户配置，将语言设置为所选语言代码（`zh-CN`、`zh-TW` 或 `zh-HK`）。
- 可选菜单项 `4` 用 `y/n` 控制 Claude Desktop 自动更新：`y` 禁止自动更新，`n` 允许自动更新。若当前存在有效的 Claude-3p `configLibrary`，脚本会写入当前 applied 配置；否则写入 `HKCU\SOFTWARE\Policies\Claude` policy。
- 可选菜单项 `5` 用 `y/n` 控制 CC Switch skills 同步：`y` 会把 `%USERPROFILE%\.cc-switch\skills` 中缺失的 skill 以软链接加入 Claude Desktop 的本地 skills 目录，并把 `SKILL.md` frontmatter 里的 `name` 和 `description` 写入对应 `manifest.json`；`n` 只删除之前同步产生、且指向 CC Switch skills 目录内的软链接和对应 manifest 记录。脚本会从当前用户的 AppData 动态扫描 Claude-3p skills plugin，不写死 session UUID，不覆盖同名 skill，也不删除 CC Switch 源目录。
- 重启 Claude Desktop。
- 可选菜单项 `3` 为 Frida 实验启动：不改官方包；自动检测或下载便携 Python+frida 到 `%LOCALAPPDATA%\claude-zh\runtime`；用内存补丁打开 CDP 并注入在线 DOM 汉化。失败时优先怀疑 AppX 注入策略 / Defender，而不是补丁包损坏。

## Linux 脚本会做什么

- 查找 deb 包安装的 Claude Desktop 资源目录（默认 `/usr/lib/claude-desktop/resources`，可用环境变量 `CLAUDE_RESOURCES` 指定），并关闭该安装目录下正在运行的 Claude Desktop 进程。
- 读取 Claude Desktop 版本号，与上次备份时记录的版本（`.zh-orig-version`）比较；版本变化说明应用已升级，会丢弃旧版本备份，从升级后的新文件重新备份，避免用旧版 `app.asar` 覆盖新版本。
- 合并当前 Claude 版本的英文语言文件与随包中文翻译（当前版本已有中文翻译的 key 会变中文，新版本新增但本包没有的 key 保留英文），写入安装目录：
  - `resources/frontend-zh-CN.json` / `frontend-zh-TW.json` / `frontend-zh-HK.json` -> `ion-dist/i18n/` 对应语言代码 `.json`（以及 `.overrides.json`）
  - `resources/desktop-zh-CN.json` / `desktop-zh-TW.json` / `desktop-zh-HK.json` -> `resources/` 对应语言代码 `.json`
- 备份前端 bundle 为同目录的 `*.zh-orig`，然后给语言白名单加入当前选择的中文变体，并修正中文语言显示名称。
- 备份 `app.asar` 为 `app.asar.zh-orig`，每次都基于这份原始备份重新打补丁（可重复运行）：由 `scripts/patch_linux_asar.py` 复用 `patch_claude_zh_cn.py` 的逻辑，注入在线账号页面 DOM 翻译和语言锁定。Linux 版 Electron 不校验 `app.asar` 完整性，因此不需要 macOS 的重签名步骤。
- 打完补丁后校验 `app.asar` 中确实写入了补丁标记；如果 Claude 新版本改动了代码结构导致补丁没有生效，会报错退出，而不是静默跳过。
- 写入 `~/.config/Claude/config.json`，设置 `"locale"` 为所选语言代码（`zh-CN`、`zh-TW` 或 `zh-HK`）。
- 恢复 / 卸载时删除三种中文资源，用 `*.zh-orig` 备份还原前端 bundle 和 `app.asar`，清除版本记录，并把用户语言设置恢复为 `en-US`。

## 卸载 / 恢复

执行对应平台的安装入口并选择「恢复原样 / 卸载补丁」（macOS 和 Windows 为 `4`，Linux 为 `2`）。macOS 会恢复 `/Applications` 下最早的 `Claude.backup-before-zh-CN-*.app` 并删除其他补丁备份；Windows 会恢复备份文件、删除三种中文资源并把用户语言设置恢复为 `en-US`；Linux 会用备份还原前端 bundle 和 `app.asar`、删除三种中文资源并把用户语言设置恢复为 `en-US`（也可直接运行 `./install-linux.sh uninstall`）。

## 注意事项

- Claude Desktop 更新可能覆盖补丁。建议先恢复补丁，再更新 Claude Desktop，最后使用本项目最新版本重新安装。
- macOS 两种安装模式都会对修改后的应用做本机 ad-hoc 重签名；Windows 模式 2 会破坏 `Claude.exe` 的 Authenticode 签名。签名相关功能是否可用，应以当前 Claude Desktop 版本的实际验证结果为准。
- Linux 仅支持官方 deb 包安装（`/usr/lib/claude-desktop`）；AppImage、Flatpak、Snap 等安装方式的目录结构不同，暂不支持。Linux 脚本不做重签名，暂不包含前端 bundle 硬编码文本汉化、主进程菜单汉化和第三方网关模型名校验绕过。
- 在线账号页面由 `claude.ai` 动态更新，DOM 汉化依赖英文原文匹配；上游文案变化后可能出现少量漏翻，需要更新本项目词表。

## Star History

<a href="https://www.star-history.com/?type=date&repos=javaht%2Fclaude-desktop-zh-cn">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=javaht/claude-desktop-zh-cn&type=date&theme=dark&legend=top-left&sealed_token=nC4gK9npC6J22iJX6ySvcDb9bLLzJi92ny-y20orz28GWvjXDHLZDuo0vqfJ7odAe7h_TdxZVOFEAXl290Auc3da0o8fLzdK6F6vAbUoM1d3_L0A7tklYQ" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=javaht/claude-desktop-zh-cn&type=date&legend=top-left&sealed_token=nC4gK9npC6J22iJX6ySvcDb9bLLzJi92ny-y20orz28GWvjXDHLZDuo0vqfJ7odAe7h_TdxZVOFEAXl290Auc3da0o8fLzdK6F6vAbUoM1d3_L0A7tklYQ" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=javaht/claude-desktop-zh-cn&type=date&legend=top-left&sealed_token=nC4gK9npC6J22iJX6ySvcDb9bLLzJi92ny-y20orz28GWvjXDHLZDuo0vqfJ7odAe7h_TdxZVOFEAXl290Auc3da0o8fLzdK6F6vAbUoM1d3_L0A7tklYQ" />
 </picture>
</a>

## 免责声明

本项目为非官方中文补丁，会修改本机 Claude Desktop 的资源文件及相关本地配置，不会修改 Claude 服务端账号数据。Claude Desktop 更新后资源结构可能变化；若补丁失败，请先恢复原版应用并更新本项目，不要在安装未完成的状态下反复运行脚本。
