# Claude-Zh

一个基于 Rust 与 Tauri 的 Claude Desktop 中文工具仓库，用于安装中文语言资源、恢复补丁，并提供桌面端图形界面。

> **欢迎贡献！** 请阅读 [贡献指南](CONTRIBUTING.md) 了解如何参与。

## 项目结构

- `crates/core` ：跨平台补丁核心逻辑。
- `crates/platform` ：macOS 与 Windows 平台适配。
- `apps/desktop` ：Tauri 2 桌面应用。
- `resources` ：随包分发的中文资源文件。

## 开发环境

- Rust 工具链
- Node.js 与 npm
- Windows 或 macOS

## 开发命令

在仓库根目录执行 Rust 相关命令：

```bash
cargo check --workspace
cargo test
```

在 `apps/desktop` 目录执行前端与 Tauri 相关命令：

```bash
cd apps/desktop
npm install
npm run build
npm run tauri build
```

## 说明

当前仓库以根目录的 Rust / Tauri 主仓结构为准：`Cargo.toml` 统一管理工作区成员，桌面应用相关配置位于 `apps/desktop` 与 `apps/desktop/src-tauri` ，中文资源位于 `resources` 目录。安装、恢复与打包流程均围绕 Tauri 桌面应用展开。

## 贡献指南

欢迎参与贡献！请阅读以下文档了解协作规范：

- [贡献指南](CONTRIBUTING.md) ：开发环境、分支规范、提交格式、PR 流程
- [行为准则](CODE_OF_CONDUCT.md) ：社区行为规范
- [安全政策](SECURITY.md) ：漏洞报告流程
- [支持渠道](SUPPORT.md) ：获取帮助的方式

### 协作规范

项目提供完整的中文 GitHub 协作规范，详见 [规范文档](docs/git/spec.md) ：

- Commit 格式：`<type>(<scope>): <中文描述>`
- 分支命名：`<type>/<english-kebab-description>`
- PR 标题：与 commit 格式一致，CI 自动校验
- Issue 模板：Bug 报告、功能建议、问题咨询
