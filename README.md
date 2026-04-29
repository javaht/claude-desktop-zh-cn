# Claude Desktop 中文补丁（zh-CN）

一个用于 macOS 版 Claude Desktop 的中文界面补丁。把本项目下载到本地后，双击 `install.command`，即可给 Claude Desktop 添加 `中文（中国）` 语言选项，并安装中文界面资源。

本汉化方案仅支持使用 API 的方式。

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=javaht/claude-desktop-zh-cn&type=Date)](https://www.star-history.com/#javaht/claude-desktop-zh-cn&Date)

## 功能特点

- 一键安装 Claude Desktop 中文界面资源。
- 自动给 Claude 前端语言白名单加入 `zh-CN`。
- 自动合并当前 Claude 版本的英文语言文件与随包中文翻译。
- 新版本新增但暂未翻译的字段会保留英文，避免界面缺失文本。
- 安装前自动备份原始 `/Applications/Claude.app`。
- 自动写入 Claude 用户配置，将语言设置为 `zh-CN`。

## 适用环境

- macOS
- 已安装 Claude Desktop
- 系统自带 Python 3（通常路径为 `/usr/bin/python3`）

## 使用方式

1. 退出 Claude Desktop。
2. 下载或克隆本项目。
3. 双击 `install.command`。
4. 按提示输入 Mac 登录密码。
5. Claude 会自动重新打开。
6. 如果没有自动切换，打开左下角账号菜单，选择 `Language` -> `中文（中国）`。

也可以在终端运行：

```bash
cd /path/to/claude-desktop-zh-cn
sudo /usr/bin/python3 patch_claude_zh_cn.py --user-home "$HOME" --launch
```

## 从 GitHub 下载

```bash
git clone https://github.com/<your-name>/claude-desktop-zh-cn.git
cd claude-desktop-zh-cn
./install.command
```

如果 `install.command` 无法双击运行，可以先执行：

```bash
chmod +x install.command
./install.command
```

## 文件说明

- `install.command`：双击运行入口。
- `patch_claude_zh_cn.py`：真正执行补丁的 Python 脚本。
- `resources/manifest.json`：语言包信息。
- `resources/frontend-zh-CN.json`：Claude 前端界面中文翻译。
- `resources/desktop-zh-CN.json`：Claude 桌面壳层中文翻译。
- `resources/Localizable.strings`：macOS 原生菜单中文资源。
- `resources/statsig-zh-CN.json`：statsig i18n 兜底资源。

## 脚本会做什么

- 备份当前 `/Applications/Claude.app` 到同目录，名字类似：
  `Claude.backup-before-zh-CN-20260424-120000.app`
- 复制 Claude.app 到临时目录并打补丁。
- 给前端语言白名单加入 `zh-CN`。
- 合并当前 Claude 版本的 `en-US.json` 和随包中文翻译：
  当前版本已有中文翻译的 key 会变中文，新版本新增但本包没有的 key 会保留英文，避免应用缺字段。
- 写入 `~/Library/Application Support/Claude/config.json`，设置 `"locale": "zh-CN"`。
- 对修改后的 Claude.app 及其内部 app/framework/原生二进制做一致的本机 ad-hoc 重签名，并清除 `com.apple.quarantine` 隔离属性。
- 重新启动 Claude。

## 注意

Claude Desktop 更新后可能会覆盖补丁，需要重新运行 `install.command`。

如果打开后 macOS 提示无法验证开发者或应用损坏，通常是因为 Claude Desktop 更新后，补丁修改资源文件导致原始签名失效。新版脚本会自动执行本机 ad-hoc 重签名、保留原 app 的 entitlements，并确保内部 app/framework 使用一致签名；如果你已经用旧版脚本打过补丁且遇到 `virtualization_entitlement_missing` / `Claude 的安装似乎已损坏`，请先恢复备份或重新安装官方 Claude.app，再重新运行 `install.command`。

不要只手动运行单条 `codesign --deep` 命令修复当前应用。Claude.app 内部还有 Electron Framework、Helper app、`.node` 原生模块和动态库，单条命令容易造成主程序和内部 framework 的 Team ID 不一致，启动时会出现 `mapping process and mapped file ... have different Team IDs`。请重新运行 `install.command`，让脚本按从内到外的顺序重签。

## 卸载 / 恢复

脚本安装前会在 `/Applications` 下生成备份，名称类似：

```text
Claude.backup-before-zh-CN-20260424-120000.app
```

如需恢复，可退出 Claude Desktop 后，将当前 `/Applications/Claude.app` 移走，再把备份 app 改名为 `Claude.app`。

## 免责声明

本项目为非官方中文补丁，仅修改本机 Claude Desktop 的本地资源文件。Claude Desktop 更新后资源结构可能变化，若补丁失败，请先更新本项目或重新运行安装脚本。
