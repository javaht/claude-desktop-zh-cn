# Claude Desktop 汉化补丁 - Agent 交接文档

## 项目状态

- 仓库：`javaht/claude-desktop-zh-cn`
- 分支：`main`
- 当前主线：根目录 Rust / Tauri 主仓

## 当前结构

- `Cargo.toml`：工作区入口，统一管理 Rust 成员。
- `crates/core`：跨平台补丁核心逻辑。
- `crates/platform`：Windows / macOS 平台适配、路径与提权相关逻辑。
- `apps/desktop`：Tauri 桌面应用前端。
- `apps/desktop/src-tauri`：Tauri 2 后端、打包与安装器配置。
- `resources/`：随应用分发的中文资源文件。
- `docs/`：GitHub Pages 文档站点。
- `.github/workflows/`：CI / CD 工作流。

## 常用命令

- 工作区检查：`cargo check --workspace`
- 工作区测试：`cargo test`
- 前端依赖安装：`cd apps/desktop && npm install`
- 桌面端构建：`cd apps/desktop && npm run build`
- Tauri 打包：`cd apps/desktop && npm run tauri build`

## 交接注意事项

- 当前安装、恢复与打包流程以 Tauri 桌面应用和其安装器为准。
- 修改安装相关文档时，优先对齐 `apps/desktop/src-tauri/tauri.conf.json` 中的目标平台与打包配置。
- 补丁仍会修改本地 `Claude Desktop` 资源，验证前请完全退出应用。
- 若 `Claude Desktop` 更新导致资源变化，需要重新执行安装或恢复后的验证流程。
