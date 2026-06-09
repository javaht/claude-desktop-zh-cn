# 快速开始

1. 先阅读 `docs/agent/AGENT_HANDOFF.md`，确认当前仓库以根目录 Rust / Tauri 主仓结构为准。
2. 在仓库根目录运行 `cargo check --workspace` 与 `cargo test`，确认 Rust 工作区状态正常。
3. 如需验证桌面端，进入 `apps/desktop` 后运行 `npm install`、`npm run build`，必要时执行 `npm run tauri build`。
4. 处理文档、安装或资源相关改动时，优先核对 `resources/`、`apps/desktop` 与 `apps/desktop/src-tauri` 三处是否一致。
5. 完成修改后，至少补做一次与你变更范围对应的自查或构建验证。
