# 贡献指南

感谢你对 Claude Desktop 中文补丁项目的关注！

## 快速开始

### 开发环境

- Rust 工具链（rustup）
- Node.js 22+ 与 npm
- Windows 或 macOS 操作系统

### 本地开发

```bash
# 克隆仓库
git clone https://github.com/javaht/claude-desktop-zh-cn.git
cd claude-desktop-zh-cn

# 检查 Rust 工作区
cargo check --workspace
cargo test

# 启动桌面应用开发
cd apps/desktop
npm install
npm run dev

# 构建安装包
npm run tauri build
```

## 协作规范

完整的协作规范详见 [规范文档](docs/git/spec.md)，以下是核心要点：

### Commit 格式

```
<type>(<scope>): <中文描述>
```

- `type`：`feat`、`fix`、`docs`、`style`、`refactor`、`perf`、`test`、`chore`、`ci`、`revert`
- `scope`（可选）：`安装器`、`核心`、`前端`、`平台`、`CI`、`文档`、`发布`、`依赖`、`仓库结构`
- `description`：中文动宾短语，不超过 50 字符

示例：

```bash
git commit -m "feat(安装器): 添加 Windows 安装前环境检查"
git commit -m "fix(平台): 修复 macOS 恢复流程路径判断"
git commit -m "docs(规范): 新增中文 GitHub 协作规范"
```

### 分支命名

```
<type>/<english-kebab-description>
```

示例：`feat/install-progress-bar`、`fix/windows-scheduled-task`

### PR 标题

PR 标题与 commit 格式保持一致，CI 会自动校验。不符合规范的 PR 无法合并。

### 审查分级

- **[必须修复]**：安全漏洞、数据丢失、逻辑错误
- **[建议修改]**：性能问题、可维护性
- **[仅供参考]**：命名优化、风格建议
- **[问题]**：需要解释意图

## Fork 工作流

如果你是第一次贡献，请按以下流程操作：

1. Fork 本仓库到你的 GitHub 账号
2. 克隆你的 Fork：`git clone https://github.com/<你的用户名>/claude-desktop-zh-cn.git`
3. 添加上游仓库：`git remote add upstream https://github.com/javaht/claude-desktop-zh-cn.git`
4. 创建分支：`git checkout -b feat/your-feature`
5. 开发完成后推送：`git push origin feat/your-feature`
6. 在 GitHub 上创建 PR，目标分支选择 `main`

## 提交前检查

- [ ] `cargo check --workspace` 通过
- [ ] `cargo test` 通过
- [ ] 如有前端变更，`npm run build` 通过
- [ ] 如涉及安装器，测试过安装/卸载流程
- [ ] commit 格式符合规范
- [ ] 分支已 rebase 到最新的 `main`

## 获取帮助

- [问题反馈](https://github.com/javaht/claude-desktop-zh-cn/issues/new?template=bug-report.yml)：报告 Bug
- [功能建议](https://github.com/javaht/claude-desktop-zh-cn/issues/new?template=feature-request.yml)：提出建议
- [问题咨询](https://github.com/javaht/claude-desktop-zh-cn/issues/new?template=question.yml)：使用问题
- [GitHub Discussions](https://github.com/javaht/claude-desktop-zh-cn/discussions)：参与讨论

## 行为准则

本项目遵循 [Contributor Covenant 行为准则](CODE_OF_CONDUCT.md)。参与贡献即表示你愿意遵守该准则。
