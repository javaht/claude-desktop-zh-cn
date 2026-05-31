# Claude Desktop 汉化补丁 - Agent 交接文档

## 项目状态
- 仓库：javaht/claude-desktop-zh-cn
- 分支：main（主分支）

## 项目结构
- `scripts/patch_claude_zh_cn.py` — 主补丁脚本（macOS + Windows）
- `resources/` — 中文翻译资源文件（zh-CN、zh-TW、zh-HK）
- `install-mac.command` — macOS 安装入口
- `install-windows.bat` — Windows 安装入口
- `docs/` — GitHub Pages 文档网站
- `.github/workflows/` — CI/CD 工作流

## 常用命令
- macOS 安装：`sudo python3 scripts/patch_claude_zh_cn.py --app /Applications/Claude.app`
- Windows 安装：右键 `install-windows.bat` 以管理员身份运行
- 卸载/恢复：运行安装脚本，选择恢复选项

## 注意事项
- 补丁会修改 Claude Desktop 的本地资源文件
- 安装前请完全退出 Claude Desktop
- 更新 Claude 后可能需要重新运行补丁
