# Claude Desktop 汉化补丁 - Agent 交接文档

## 项目状态
- 仓库：javaht/claude-desktop-zh-cn
- 分支：main（主分支）

## 项目结构
- `scripts/patch_claude_zh_cn.py` — macOS 补丁、诊断和安全提交脚本
- `scripts/macos_auto_repair.py` — macOS LaunchDaemon 更新检测与自动修复控制器
- `scripts/install_windows.ps1` — Windows 补丁、卸载和计划任务维护脚本
- `resources/` — 中文翻译资源文件（zh-CN、zh-TW、zh-HK）
- `install-mac.command` — macOS 安装入口
- `install-windows.bat` — Windows 安装入口
- `tests/test_patcher.py` — 不依赖 Claude 安装的跨版本兼容与回滚测试
- `docs/` — GitHub Pages 文档网站
- `.github/workflows/` — CI/CD 工作流

## 常用命令
- macOS 安装：`sudo python3 scripts/patch_claude_zh_cn.py --app /Applications/Claude.app`
- macOS 只读诊断：`python3 scripts/patch_claude_zh_cn.py --doctor --json`
- Windows 安装：右键 `install-windows.bat` 以管理员身份运行
- 卸载/恢复：运行安装脚本，选择恢复选项
- 回归测试：`python3 -m unittest discover -s tests -v`
- Python 语法：`python3 -m py_compile scripts/patch_claude_zh_cn.py scripts/macos_auto_repair.py`
- macOS 入口语法：`bash -n install-mac.command`

## 注意事项
- 补丁会修改 Claude Desktop 的本地资源文件，并安装系统级自动修复服务
- 安装前请完全退出 Claude Desktop
- 不得恢复没有有效 marker 或与当前 build/源指纹不匹配的旧备份，以免把官方新版降级
- 前端资源必须按语义和递归布局发现，不能重新写死 `assets/v1`、固定 hash 文件名或完整语言数组
- 新版英文资源与项目中文词表按 key 合并；未翻译的新 key 保留英文
- 完整模式不兼容时先回滚并退到基础模式；基础模式不得读写 `app.asar` 或可执行文件完整性信息
- macOS 自动修复 payload 位于 `/Library/Application Support/ClaudeDesktopZhCN`；Windows 位于 `%ProgramData%\ClaudeDesktopZhCn`。两者都禁止从网络下载并以 root/SYSTEM 执行代码
