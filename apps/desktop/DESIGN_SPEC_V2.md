# Claude-Zh 桌面客户端设计规范 V2

## 1. 产品定位与重构目标

**Claude-Zh** 是 Claude Desktop 的汉化补丁安装器，面向 macOS / Windows 桌面用户。本规范覆盖 **PR3 视觉落地**后的最终形态。

**重构目标（V2）**
- 从 4 面板信息架构收束为 **「极简单页 + 设置抽屉」**，降低认知负荷。
- 视觉对标 claude.com/solutions/legal：大留白、暖中性色、衬线标题、柔和质感。
- 不动业务逻辑与 Rust 层，仅做视觉与交互细节落地。

---

## 2. 信息架构

```
┌─────────────────────────────────────┐
│ TitleBar (macOS 自绘 / Windows 原生) │
├─────────────────────────────────────┤
│  ┌─────────────────────────────┐   │
│  │         max-w-xl            │   │
│  │  ┌─────────────────────┐   │   │
│  │  │ [设置] 图标按钮      │   │   │
│  │  └─────────────────────┘   │   │
│  │                              │   │
│  │  StatusSummary               │   │
│  │  · 状态行 + Tooltip 路径     │   │
│  │  · 警告 banner（条件显示）   │   │
│  │                              │   │
│  │  ┌─────────────────────┐   │   │
│  │  │   安装中文补丁        │   │   │  ← 主 CTA
│  │  └─────────────────────┘   │   │
│  │  配置摘要（居中 muted）      │   │
│  │  进度提示（条件显示）        │   │
│  │                              │   │
│  │  LogPanel（可折叠）          │   │
│  │  · 终端风格固定暗色日志区    │   │
│  │                              │   │
│  └─────────────────────────────┘   │
└─────────────────────────────────────┘
│
▼  SettingsDrawer（右侧 Sheet, 420px）
    ┌─────────────────────────────┐
    │  设置                        │  ← font-serif 标题
    │  调整安装选项、自动更新…       │
    ├─────────────────────────────┤
    │  安装选项                     │  ← Section 标题
    │  ├─ 语言 / 模式              │
    │  └─ 安装后启动 / 试运行      │
    ├─────────────────────────────┤
    │  更新                         │
    │  └─ 自动更新 Switch          │
    ├─────────────────────────────┤
    │  维护                         │
    │  └─ 恢复补丁                 │
    ├─────────────────────────────┤
    │  关于                         │
    │  └─ Claude-Zh / v0.1.6       │
    └─────────────────────────────┘
```

---

## 3. Design Tokens

### 3.1 颜色（HSL CSS Variables）

| Token | Light | Dark | 用途 |
|---|---|---|---|
| `--background` | `40 20% 97%` | `240 6% 10%` | 页面底色 |
| `--foreground` | `240 8% 12%` | `40 20% 96%` | 主文字 |
| `--card` | `40 20% 99%` | `240 5% 14%` | 卡片/面板背景 |
| `--card-foreground` | `240 8% 12%` | `40 20% 96%` | 卡片内主文字 |
| `--popover` | `40 20% 99%` | `240 5% 14%` | 下拉浮层 |
| `--popover-foreground` | `240 8% 12%` | `40 20% 96%` | 浮层文字 |
| `--primary` | `15 58% 59%` | `15 58% 59%` | 主按钮/强调（暖橙 #D97757） |
| `--primary-foreground` | `40 20% 99%` | `40 20% 99%` | 主按钮文字 |
| `--secondary` | `40 15% 94%` | `240 5% 18%` | 次要背景 |
| `--secondary-foreground` | `240 8% 12%` | `40 20% 96%` | 次要文字 |
| `--muted` | `40 15% 95%` | `240 5% 18%` | 占位/悬浮背景 |
| `--muted-foreground` | `240 3% 60%` | `240 4% 55%` | 辅助文字 |
| `--accent` | `40 15% 94%` | `240 5% 18%` | 悬停高亮背景 |
| `--accent-foreground` | `240 8% 12%` | `40 20% 96%` | 悬停高亮文字 |
| `--destructive` | `0 65% 55%` | `0 65% 55%` | 危险操作 |
| `--destructive-foreground` | `40 20% 99%` | `40 20% 99%` | 危险按钮文字 |
| `--border` | `40 10% 88%` | `240 4% 20%` | 边框/分割线 |
| `--border-subtle` | `40 10% 93%` | `240 4% 16%` | 弱边框 |
| `--input` | `40 10% 88%` | `240 4% 20%` | 输入框边框 |
| `--ring` | `15 58% 59% / 0.35` | `15 58% 59% / 0.35` | focus ring |
| `--radius` | `0.625rem` | `0.625rem` | 全局圆角基准 |
| `--success` | `145 50% 42%` | `145 45% 48%` | 成功状态 |
| `--warning` | `38 85% 52%` | `38 80% 58%` | 警告状态 |
| `--warning-foreground` | `38 70% 35%` | `38 80% 65%` | 警告 banner 文字 |
| `--error` | `0 65% 55%` | `0 70% 60%` | 错误状态 |

**说明**
- `--background` 暖米白（约 `#FAFAF6`），比纯白柔和，降低眩光。
- `--primary` 保持暖橙，只在主 CTA 出现，克制使用。
- `--warning-foreground` 在 dark 下提亮至 `38 80% 65%`，保证对比度。

### 3.2 字号

沿用 Tailwind 默认阶梯，关键语义映射：

| Tailwind 类 | 用途 |
|---|---|
| `text-xs` | 标签、日志时间戳、版本号 |
| `text-sm` | 辅助文字、按钮内文字、选项说明 |
| `text-base` | 正文、面板标题、状态摘要 |
| `text-lg` | Sheet 标题（衬线） |

### 3.3 圆角

| 变量 | 值 | 用途 |
|---|---|---|
| `--radius` | `0.625rem`（10px） | 卡片、Sheet、主按钮 |
| `rounded-md` | `calc(var(--radius) - 2px)`（8px） | 标准按钮 |
| `rounded-sm` | `calc(var(--radius) - 4px)`（6px） | 输入框、小按钮 |

### 3.4 间距

| 场景 | Tailwind 类 |
|---|---|
| 主视图板块间 | `gap-8` ~ `gap-10` |
| 主按钮上下留白 | `my-8` |
| 抽屉 Section 之间 | `space-y-6` ~ `space-y-8` |
| Section 内字段间 | `space-y-3` ~ `space-y-4` |
| 全局内容边距 | `px-4` / `px-6` |

### 3.5 阴影

- 浅色：`shadow-sm`（`0 1px 2px hsl(240 8% 12% / 0.04)`）
- 深色：无阴影或仅 `shadow-sm`（`0 1px 2px hsl(0 0% 0% / 0.20)`）
- 禁止多层阴影堆叠。

### 3.6 Z-Index

| 层级 | 值 | 用途 |
|---|---|---|
| `--z-titlebar` | `50` | 自绘标题栏 |
| `--z-dropdown` | `100` | Select / Tooltip |
| `--z-dialog` | `200` | AlertDialog |
| `--z-toast` | `300` | Sonner toast |

---

## 4. 字体策略

### 4.1 字体栈

**无衬线（Sans）**：`ui-sans-serif, -apple-system, BlinkMacSystemFont, "PingFang SC", "Microsoft YaHei", "Source Han Sans CN", sans-serif`

**衬线（Serif）**：`ui-serif, "Source Serif Pro", Charter, Cambria, "Times New Roman", serif`

**等宽（Mono）**：`JetBrains Mono, ui-monospace, SFMono-Regular, Menlo, monospace`

### 4.2 使用边界

| 元素 | 字体 | 说明 |
|---|---|---|
| Sheet 标题（`SheetTitle`） | `font-serif` | 唯一一处大字号衬线，增加质感 |
| 抽屉内 Section 标题 | `font-serif` | 节制使用，与无衬线正文形成对比 |
| 状态摘要、正文、按钮 | `font-sans` | 保持可读性与现代感 |
| 日志内容、路径 | `font-mono` | 等宽保留 |
| 配置摘要、标签 | `font-sans` | 小字号辅助信息，不抢视觉重心 |

**约束**：全应用 `font-serif` 出现不超过 5 处。

---

## 5. 主视图视觉规格

### 5.1 整体布局

```
主视图
├── 设置按钮（右上角，独立行）
├── gap-8
├── StatusSummary
│   ├── 状态行（图标 + 路径 Tooltip + meta）
│   └── 警告 banner（条件显示，圆角边框 + 淡背景）
├── gap-8
├── 主操作区
│   ├── 安装中文补丁（主 CTA，w-full, h-12, rounded-lg）
│   ├── 配置摘要（text-xs, text-muted-foreground, text-center）
│   └── 进度提示（条件显示，border + bg-muted/50）
├── flex-1（弹性占位，将日志推至底部）
└── LogPanel（可折叠）
```

### 5.2 StatusSummary

- **状态行**：`flex items-center gap-3`，图标 16px，路径文字 `text-sm font-medium truncate`，meta `text-xs text-muted-foreground`。
- **刷新按钮**：`variant="ghost" size="icon"`，Hover `bg-muted`，Active `scale-95`。
- **警告 banner**：`rounded-lg border p-3`，背景与边框使用 `--warning` 透明度，文字使用 `--warning-foreground`。
- **dark 模式**：banner 边框/背景透明度提高至 `0.20` / `0.12`，文字提亮。

### 5.3 主按钮

- 样式：`w-full h-12 text-base font-semibold rounded-lg`
- Hover：`bg-primary/90`
- Active：`scale-[0.98]`
- Disabled：`opacity-50 cursor-not-allowed`
- Loading：内部图标与文字交叉淡入，按钮宽度保持固定。

### 5.4 配置摘要

- `text-xs text-muted-foreground text-center`
- 内容：`语言 · 模式 · 试运行 开启/关闭`
- 视觉权重极低，作为附注存在。

### 5.5 LogPanel

**折叠态（Header）**
- 高度 48px，flex 居中，圆角与卡片一致。
- 左侧：`Terminal` 图标 + "执行日志" + 条目数。
- 右侧：`ChevronUp`（折叠）/ `ChevronDown`（展开）。
- 视觉低调：`text-sm font-medium text-card-foreground`，不抢主按钮。

**展开态**
- 日志区域：固定暗色 `hsl(220 15% 8%)`，`max-h-[40vh]`，确保最小窗口不溢出。
- 日志文字：`text-xs font-mono`，级别分色（error/warn/info）。
- 折叠/展开：CSS `transition-all duration-200 ease-out`，使用 `grid grid-rows-[0fr]` → `grid-rows-[1fr]`  trick 实现平滑高度过渡。

---

## 6. 抽屉视觉规格

### 6.1 整体布局

```
SettingsDrawer（Sheet, right, w-[min(420px,92vw)]）
├── SheetHeader
│   ├── SheetTitle "设置"          ← font-serif, text-lg
│   └── SheetDescription           ← text-sm text-muted-foreground
├── 内容区 px-6 py-5 space-y-6
│   ├── Section: 安装选项
│   │   ├── SectionTitle           ← font-serif, text-base
│   │   ├── 字段网格（2-col）
│   │   └── Checkboxes（横向排列）
│   ├── Separator
│   ├── Section: 更新
│   │   ├── SectionTitle           ← font-serif, text-base
│   │   └── Switch 行
│   ├── Separator
│   ├── Section: 维护
│   │   ├── SectionTitle           ← font-serif, text-base
│   │   └── 恢复补丁 Button
│   ├── Separator
│   └── Section: 关于
│       ├── SectionTitle           ← font-serif, text-base
│       └── 版本信息
```

### 6.2 Section 标题

- `font-serif text-base font-medium text-foreground`
- 与正文的无衬线形成对比，提升抽屉质感。

### 6.3 字段与控件

- **Select 标签**：`text-xs font-medium text-muted-foreground uppercase tracking-wide`
- **Select Trigger**：`rounded-md`，Hover `border-border/80`，Focus `ring-2 ring-primary/20`
- **Checkbox + Label**：`flex items-center gap-2`，Label `text-sm font-medium`
- **Switch**：标准 shadcn Switch，无额外覆盖。
- **Button（恢复补丁）**：`variant="outline" w-full justify-start`，图标左对齐。

---

## 7. 窗口形态决策

| 平台 | 标题栏 | 说明 |
|---|---|---|
| macOS | 自绘 + 红绿灯 | 高度 28px，`data-tauri-drag-region` 支持拖拽。红绿灯使用固定色 `#FF5F57` / `#FEBC2E` / `#28C840`。 |
| Windows | 强制原生标题栏 | WebView2 存在 BitBlt 像素渲染问题，自绘会导致标题栏黑/白块。已通过原生标题栏规避，不改回自绘。 |

---

## 8. 主题策略

- **跟随系统**：通过 `useTheme` hook 监听系统主题变化，在 `<html>` 上切换 `.dark` class。
- **darkMode: class**：Tailwind 配置使用 `darkMode: ["class"]`，由 React 运行时控制。
- **无全局过渡动画**：主题切换即时生效，避免闪烁。
- **日志面板固定暗色**：不随系统主题切换，保持终端心智模型与对比度稳定。

---

## 9. 动效规范

### 9.1 通用参数

| 场景 | Duration | Easing | 实现方式 |
|---|---|---|---|
| 颜色 Hover | `0.15s` | `ease` | Tailwind `transition-colors` |
| Active 按压 | `0.08s` | `ease` | `scale-[0.98]` |
| Focus Ring | 即时 | — | `box-shadow` |
| 面板/卡片入场 | `0.18–0.22s` | `cubic-bezier(0.16, 1, 0.3, 1)` | framer-motion |
| LogPanel 折叠/展开 | `0.2s` | `ease-out` | CSS `transition-all` |

### 9.2 framer-motion 使用范围

- **保留**：LogPanel 空状态淡入（`duration: 0.2s`）。
- **不使用**：LogPanel 展开/收起（改用 CSS transition，避免高度动画与 motion 冲突导致抖动）。
- **Sheet 滑入**：保留 shadcn Sheet 默认动画，不自定义。

### 9.3 主按钮交互

- Hover：`bg-primary/90`，`transition-colors duration-150`
- Active：`active:scale-[0.98]`，`transition-transform duration-100`

---

## 10. 明暗走查清单

| 检查项 | Light 状态 | Dark 状态 | 结果 |
|---|---|---|---|
| 主按钮文字对比度 | `#FDFCFA` 在 `#D97757` 上 | 同上 | ✅ 通过 |
| StatusSummary 警告 banner 可读性 | 文字 `hsl(38 70% 35%)` 在淡橙底 | 文字 `hsl(38 80% 65%)` 在暗橙底 | ✅ 通过 |
| StatusSummary 错误 banner 可读性 | 文字 `hsl(0 60% 40%)` 在淡红底 | 文字 `hsl(0 75% 70%)` 在暗红底 | ✅ 通过 |
| LogPanel 折叠 Header 可读性 | `text-card-foreground` 在 `--card` | 同上 | ✅ 通过 |
| LogPanel 展开日志区对比度 | 固定暗底，info/warn/error 分色 | 固定暗底，不受主题影响 | ✅ 通过 |
| Sheet 内部 Section 标题层次 | `font-serif` 大标题 vs `text-xs uppercase` 标签 | 同上 | ✅ 通过 |
| 配置摘要文字可读性 | `text-muted-foreground` 在 `--background` | `text-muted-foreground` 在 dark bg | ✅ 通过 |
| Settings 图标按钮 Hover | `bg-muted` 可见 | `bg-muted` 可见 | ✅ 通过 |
| AlertDialog 按钮对比度 | Primary / Outline 均清晰 | 同上 | ✅ 通过 |
| 进度提示条背景 | `bg-muted/50` 足够区分 | `bg-muted/50` 足够区分 | ✅ 通过 |

---

## 11. 最小窗口响应式规则

**Tauri 配置**：`minWidth: 760`, `minHeight: 620`

| 场景 | 规则 |
|---|---|
| 主视图溢出 | `main` 区域 `overflow-y-auto`，内容超出时可整体垂直滚动。 |
| Sheet 宽度 | `w-[min(420px,92vw)]`，在小窗口下自适应。 |
| LogPanel 展开高度 | 日志区域 `max-h-[40vh]`，避免占据过多视口。 |
| 按钮与控件 | 保持 `max-w-xl` 内容栏，不溢出水平边界。 |
| TitleBar | macOS 28px / Windows 32px，内容区通过 padding 避开。 |

---

## 12. 风险与提醒

1. **Windows 标题栏不可回退自绘**：WebView2 BitBlt 渲染缺陷已在多版本验证，原生标题栏是唯一稳定方案。
2. **衬线字体栈依赖系统字体**：若用户系统无 Source Serif Pro / Charter，会 fallback 到 Cambria / Times New Roman。中文环境下衬线字体对汉字影响较小，英文标题仍能获得质感提升。
3. **LogPanel 固定暗色与主题切换**：日志区域 `background: hsl(220 15% 8%)` 为硬编码，但属于有意为之的"终端固定暗色"策略，已在规范中声明。
4. **最小窗口高度下主按钮仍应可见**：`flex-1` 弹性占位会将 LogPanel 推至底部，若日志展开后内容过长，需确保用户滚动后仍能看到主按钮。实际通过 `main` 的 `overflow-y-auto` 解决。
5. **framer-motion 与 CSS transition 混用风险**：LogPanel 展开/收起已明确使用 CSS transition，其余动画保留 framer-motion，避免同一属性两种动画引擎冲突。
6. **shadcn Select 在 Tauri WebView 中的定位**：已设置 `position="popper"`，但极小窗口下下拉仍可能被裁切。若未来用户反馈，可进一步限制 `max-height` 或改为 Sheet 内嵌列表。
