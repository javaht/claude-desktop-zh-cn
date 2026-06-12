# 中文 GitHub 协作规范

本规范适用于 Claude Desktop 中文补丁项目，目的是统一协作方式，让贡献者和维护者都能高效工作。

## 核心原则

- **中文优先**：文档、Issue、PR、Review 话术、Release 说明全部使用中文
- **工具兼容**：commit type、分支名前缀、GitHub 关键字保留英文

---

## Commit 规范

### 格式

```
<type>(<scope>): <中文描述>
```

### 类型（type）

| 类型 | 说明 |
|------|------|
| `feat` | 新功能 |
| `fix` | 修复缺陷 |
| `docs` | 文档变更 |
| `style` | 代码格式 |
| `refactor` | 重构 |
| `perf` | 性能优化 |
| `test` | 测试 |
| `chore` | 构建/工具/依赖 |
| `ci` | 持续集成 |
| `revert` | 回滚 |

### 范围（scope）

使用中文，表示影响的模块（可选）：

- `安装器`：桌面应用安装流程
- `核心`：core crate 逻辑
- `前端`：React 前端界面
- `平台`：Windows/macOS 平台适配
- `CI`：GitHub Actions 工作流
- `文档`：README、docs 等文档
- `发布`：版本发布相关
- `依赖`：依赖更新
- `仓库结构`：目录结构调整

scope 是可选的，但对于跨模块的变更（如 `chore: 升级依赖`），可以省略 scope。

### 示例

```bash
# 好的 commit
git commit -m "feat(安装器): 添加 Windows 安装前环境检查"
git commit -m "fix(平台): 修复 macOS 恢复流程路径判断"
git commit -m "docs(规范): 新增中文 GitHub 协作规范"

# 避免的写法
git commit -m "fix bug"
git commit -m "update code"
git commit -m "修改了点东西"
```

### 校验

PR 标题会自动校验格式，不符合规范的 PR 无法合并。

---

## 分支规范

### 命名格式

```
<type>/<english-kebab-description>
```

### 示例

| 分支名 | 说明 |
|--------|------|
| `feat/install-progress-bar` | 添加安装进度条 |
| `fix/windows-scheduled-task` | 修复 Windows 计划任务 |
| `docs/readme-restructure` | 重构 README 文档 |

### 规则

- 从 `main` 创建，完成后合并回 `main`
- 生命周期不超过 14 天
- 合并后删除临时分支

---

## PR 规范

### 标题格式

```
<type>(<scope>): <中文描述>
```

与 commit 格式保持一致，squash 合并后会成为 commit message。

### 提交前检查

- [ ] `cargo check --workspace` 通过
- [ ] `cargo test` 通过
- [ ] 如有前端变更，`npm run build` 通过
- [ ] 如涉及安装器，测试过安装/卸载流程

### 审查分级

| 标记 | 含义 |
|------|------|
| **[必须修复]** | 安全漏洞、数据丢失、逻辑错误 |
| **[建议修改]** | 性能问题、可维护性 |
| **[仅供参考]** | 命名优化、风格建议 |
| **[问题]** | 需要解释意图 |

### 合并方式

- 使用 **Squash and merge**
- 合并后删除临时分支

---

## Issue 规范

### 类型

| 类型 | 模板 | 用途 |
|------|------|------|
| Bug 报告 | `bug-report.yml` | 报告使用中遇到的问题 |
| 功能建议 | `feature-request.yml` | 提出新功能或改进建议 |
| 问题咨询 | `question.yml` | 使用相关问题 |

### 标题

使用中文，简洁描述问题或建议：

- ✅ 安装完成后 Claude Desktop 没有切换为中文
- ✅ 希望添加安装进度条显示
- ❌ Bug
- ❌ 问题

---

## 版本与发布

### 版本号

遵循语义化版本（SemVer）：`MAJOR.MINOR.PATCH`

- 不使用 `v` 前缀：`1.2.4` 而不是 `v1.2.4`
- 与现有 Git tags 保持一致

### 发布流程

1. 维护者在 GitHub Actions 手动触发 `Prepare Release`
2. 输入版本号（如 `1.2.4`）
3. 工作流自动更新 `resources/release.json` 并创建 tag
4. 构建工作流自动打包安装器并发布到 GitHub Release

---

## 中文排版

### 空格

- 中英文之间：`使用 Git 进行版本管理` ✅ `使用Git进行版本管理` ❌
- 中文与数字之间：`共 3 个文件` ✅ `共3个文件` ❌
- 链接前后：`请参考 [文档](url) 获取详情` ✅ `请参考[文档](url)获取详情` ❌

### 标点

- 中文语境：全角标点 `，。：；！？`
- 代码/URL：半角标点

### 技术术语

- 保留英文：Rust、Tauri、GitHub Actions、npm、cargo
- 不强行翻译：API、SDK、CLI、IDE

---

## 工具链兼容

以下内容保留英文，保证工具链兼容：

- commit `type`：`feat`、`fix`、`docs`、`ci`、`chore` 等
- 分支名前缀：`feat/`、`fix/`、`docs/` 等
- GitHub workflow 文件名、YAML key、配置字段
- `Closes #123`、`Refs #123`、`BREAKING CHANGE:` 等 GitHub 关键字
- 版本号、tag、分支名（英文短横线格式）

---

## 相关文件

- [CONTRIBUTING.md](../../CONTRIBUTING.md)：贡献指南
- [CODE_OF_CONDUCT.md](../../CODE_OF_CONDUCT.md)：行为准则
- [SECURITY.md](../../SECURITY.md)：安全政策
- [SUPPORT.md](../../SUPPORT.md)：支持渠道
