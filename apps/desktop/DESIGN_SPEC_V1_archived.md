> 已归档：被 DESIGN_SPEC_V2.md 取代（汉化补丁单页+抽屉重构）

# Claude-Zh 视觉重做方案

## 1. Design Tokens 最终定稿

以下变量可直接写入 `theme.css`，以 `:root` 提供浅色默认值，`.dark` 覆盖深色模式。

### 1.1 配色（HSL）

| Token | 浅色模式 | 深色模式 | 用途 |
|---|---|---|---|
| `--background` | `hsl(40 20% 97%)` | `hsl(240 6% 10%)` | 页面底色 |
| `--foreground` | `hsl(240 8% 12%)` | `hsl(40 20% 96%)` | 主文字 |
| `--card` | `hsl(40 20% 99%)` | `hsl(240 5% 14%)` | 卡片/面板背景 |
| `--card-foreground` | `hsl(240 8% 12%)` | `hsl(40 20% 96%)` | 卡片内主文字 |
| `--popover` | `hsl(40 20% 99%)` | `hsl(240 5% 14%)` | 下拉浮层背景 |
| `--popover-foreground` | `hsl(240 8% 12%)` | `hsl(40 20% 96%)` | 浮层文字 |
| `--primary` | `hsl(15 58% 59%)` | `hsl(15 58% 59%)` | 主按钮/强调 |
| `--primary-foreground` | `hsl(40 20% 99%)` | `hsl(40 20% 99%)` | 主按钮文字 |
| `--secondary` | `hsl(40 15% 94%)` | `hsl(240 5% 18%)` | 次要按钮背景 |
| `--secondary-foreground` | `hsl(240 8% 12%)` | `hsl(40 20% 96%)` | 次要按钮文字 |
| `--muted` | `hsl(40 15% 95%)` | `hsl(240 5% 18%)` | 占位/悬浮背景 |
| `--muted-foreground` | `hsl(240 3% 60%)` | `hsl(240 4% 55%)` | 辅助/标签文字 |
| `--accent` | `hsl(40 15% 94%)` | `hsl(240 5% 18%)` | 悬停高亮背景 |
| `--accent-foreground` | `hsl(240 8% 12%)` | `hsl(40 20% 96%)` | 悬停高亮文字 |
| `--destructive` | `hsl(0 65% 55%)` | `hsl(0 65% 55%)` | 危险操作 |
| `--destructive-foreground` | `hsl(40 20% 99%)` | `hsl(40 20% 99%)` | 危险按钮文字 |
| `--border` | `hsl(40 10% 88%)` | `hsl(240 4% 20%)` | 边框/分割线 |
| `--border-subtle` | `hsl(40 10% 93%)` | `hsl(240 4% 16%)` | 弱边框 |
| `--input` | `hsl(40 10% 88%)` | `hsl(240 4% 20%)` | 输入框边框 |
| `--ring` | `hsl(15 58% 59% / 0.35)` | `hsl(15 58% 59% / 0.35)` | focus ring |
| `--ring-offset` | `2px` | `2px` | ring 偏移 |
| `--success` | `hsl(145 50% 42%)` | `hsl(145 45% 48%)` | 成功状态 |
| `--warning` | `hsl(38 85% 52%)` | `hsl(38 80% 58%)` | 警告状态 |
| `--error` | `hsl(0 65% 55%)` | `hsl(0 70% 60%)` | 错误状态 |

**说明**
- 主色 `hsl(15 58% 59%)` 对应 `#D97757`，保持 Claude.ai 暖橙调，但降低饱和度避免荧光感。
- 深色背景 `hsl(240 6% 10%)` 为带极微蓝紫倾向的深灰，视觉上比纯黑 `#0A0A0A` 更透气。
- 浅色背景 `hsl(40 20% 97%)` 为暖米白，比纯白 `#FFFFFF` 柔和，降低屏幕眩光。

### 1.2 字号阶梯

| 名称 | 大小 | 行高 | 字重 | 用途 |
|---|---|---|---|---|
| `text-xs` | `11px` | `16px` | `400 / 500` | 日志时间戳、徽章、标签 |
| `text-sm` | `13px` | `20px` | `400 / 500` | 辅助文字、按钮内文字、选项 |
| `text-base` | `14px` | `22px` | `400 / 500` | 正文、段落、面板标题 |
| `text-md` | `15px` | `24px` | `500` | 小标题、Select 触发器文字 |
| `text-lg` | `18px` | `28px` | `500 / 600` | 区域标题、重要数值 |
| `text-xl` | `24px` | `32px` | `600` | 应用名称（TitleBar） |

### 1.3 圆角阶梯

| 名称 | 值 | 用途 |
|---|---|---|
| `radius-sm` | `6px` | 小按钮、输入框、checkbox、标签 |
| `radius-md` | `10px` | 卡片、大按钮、Select 触发器、notice |
| `radius-lg` | `14px` | 主面板、模态框容器 |
| `radius-xl` | `20px` | 特殊装饰、大浮层 |
| `radius-full` | `9999px` | Badge、Pill、Switch |

### 1.4 间距阶梯（基于 4px Grid）

| Token | 值 | Tailwind 映射参考 |
|---|---|---|
| `space-1` | `4px` | `p-1 / gap-1` |
| `space-2` | `8px` | `p-2 / gap-2` |
| `space-3` | `12px` | `p-3 / gap-3` |
| `space-4` | `16px` | `p-4 / gap-4` |
| `space-5` | `20px` | `p-5 / gap-5` |
| `space-6` | `24px` | `p-6 / gap-6` |
| `space-8` | `32px` | `p-8 / gap-8` |
| `space-10` | `40px` | `p-10 / gap-10` |

应用内全局内容边距统一为 `20px`（`space-5`）。

### 1.5 阴影阶梯

**浅色模式**

| 名称 | 值 |
|---|---|
| `shadow-sm` | `0 1px 2px hsl(240 8% 12% / 0.04)` |
| `shadow-md` | `0 4px 12px hsl(240 8% 12% / 0.06)` |
| `shadow-lg` | `0 8px 24px hsl(240 8% 12% / 0.08)` |
| `shadow-xl` | `0 16px 48px hsl(240 8% 12% / 0.10)` |

**深色模式**

| 名称 | 值 |
|---|---|
| `shadow-sm` | `0 1px 2px hsl(0 0% 0% / 0.20)` |
| `shadow-md` | `0 4px 12px hsl(0 0% 0% / 0.25)` |
| `shadow-lg` | `0 8px 24px hsl(0 0% 0% / 0.30)` |
| `shadow-xl` | `0 16px 48px hsl(0 0% 0% / 0.35)` |

卡片默认使用 `shadow-sm`（浅色）或无阴影（深色），避免多层阴影叠加造成脏感。

### 1.6 Z-Index 阶梯

| 层级 | 值 | 用途 |
|---|---|---|
| `z-titlebar` | `50` | 自绘标题栏 |
| `z-dropdown` | `100` | Select popover、Tooltip |
| `z-dialog` | `200` | AlertDialog overlay与内容 |
| `z-toast` | `300` | Sonner toast 通知 |

---

## 2. 整体布局方案

### 2.1 980 x 740 标准窗口

```
+------------------------------------------------------------+
| TitleBar (32px / macOS 28px)                               |
| [macOS 红绿灯占用左 70px]  Claude-Zh       [Win 控制 138px] |
+------------------------------------------------------------+
| 内容边距: 20px                                              |
|                                                             |
| +-- StatusPanel ----------------------------------------+  |
| | Header: "环境状态"                              [刷新]  |  |
| | +--------+ +--------+ +--------+                      |  |
| | | Card 1 | | Card 2 | | Card 3 |  gap-12            |  |
| | | 72px高 | | 72px高 | | 72px高 |                     |  |
| | +--------+ +--------+ +--------+                      |  |
| | [Notice Banner - 条件显示, 48px]                      |  |
| +-------------------------------------------------------+  |
|                    gap-16                                   |
| +-- Main Grid (2-col, gap-16) -------------------------+  |
| | +-- InstallOptions (左, flex-1) ----+ +-- ActionButtons (右, 0.55fr) + |
| | | Header: "安装选项"                 | | Header: "维护操作"              | |
| | |                                   | |                                | |
| | | [语言 Select] [模式 Select]       | | [恢复]                         | |
| | |                                   | | [允许自动更新]                 | |
| | | [Checkbox] 完成后启动 Claude      | | [停止自动更新]                 | |
| | | [Checkbox] dry-run 验证           | | [同步 skills]                  | |
| | |                                   | | [删除 skills 同步]             | |
| | | [======== 主安装按钮 ========]    | |                                | |
| | | [进度提示 - 条件显示]             | |                                | |
| | +-----------------------------------+ +--------------------------------+ |
| +--------------------------------------------------------+  |
|                    gap-16                                   |
| +-- LogPanel (可折叠, 默认 200px 高) --------------------+  |
| | Header: "执行日志"              [复制] [清空]           |  |
| | +--------------------------------------------------+  |  |
| | | pre / ScrollArea (固定暗色, 滚动)                |  |  |
| | +--------------------------------------------------+  |  |
| +--------------------------------------------------------+  |
|                                                             |
| 内容边距: 20px                                              |
+------------------------------------------------------------+
```

**尺寸拆解**
- TitleBar: `32px`（Windows） / `28px`（macOS）
- 内容区可用高度: `740 - 32 = 708px`，扣除上下边距 `40px`，剩余 `668px`
- StatusPanel: `~140px`（Header `32px` + 3-Cards `72px` + 内部间距）
- Main Grid: `~280px`（ActionButtons 列表高度决定）
- LogPanel: 默认 `200px`，最小展开高度 `160px`
- 合计: `140 + 16 + 280 + 16 + 200 = 652px`，余量 `16px`

### 2.2 760 x 620 最小窗口响应式行为

可用内容高度: `620 - 32 = 588px`，扣除边距 `40px`，剩余 `548px`。

**空间冲突**: StatusPanel + Grid + LogPanel 在紧凑高度下会溢出。

**响应式规则**
1. **StatusPanel**: 保持 3 列卡片，但卡片高度压缩为 `60px`，padding 由 `14px` 降至 `10px`。若屏幕宽度不足以撑开 3 列（< `720px`），卡片改为横向滚动或 1 列堆叠。
2. **Main Grid**: 双栏比例从 `1fr : 0.55fr` 调整为 `1fr : 0.48fr`；ActionButtons 文字允许省略或图标缩小。若高度 < `620px` 且宽度 < `840px`，ActionButtons 改为 `2 x 3` 图标网格（每个按钮 `80px x 44px`），将 Grid 高度控制在 `~220px`。
3. **LogPanel**: **强制折叠逻辑**。在最小尺寸下，LogPanel 默认只显示 Header（`48px` 高），点击 Header 展开至 `160px`。展开时若总高度溢出，主内容区允许整体垂直滚动（`overflow-y: auto`）。
4. **全局**: 当窗口高度 < `660px` 时，内容区 `overflow-y: auto` 启用，确保用户可滚动访问全部面板。

---

## 3. 每个面板的视觉规格

### 3.1 StatusPanel

**组件选择**
- 外层: `div`（无需 Card 嵌套，避免多层边框）
- Status Cards: 自定义 flex row（仿 Card 样式，但视为 Band 中的单元）
- Notice Banner: 自定义 alert 容器（或 shadcn `Alert`，但样式需覆盖）
- Refresh 按钮: shadcn `Button` variant="ghost" size="icon"

**内部信息层级**
- Section Title: `text-sm font-medium text-muted-foreground uppercase tracking-wider`
- Card Icon 容器: `40px x 40px`，`rounded-lg`，`bg-muted/60`
- Card 主值: `text-sm font-semibold text-foreground`（14px，截断显示 ellipsis）
- Card 副标签: `text-xs font-medium text-muted-foreground uppercase tracking-wide`（11px）
- Notice 标题: `text-sm font-medium text-foreground`
- Notice 详情: `text-xs text-muted-foreground`（逐行显示，最多 5 行）

**关键交互状态**
- Refresh 按钮 Hover: `bg-muted`，`transition-colors 0.15s ease`
- Refresh 按钮 Active: `scale-95`，`transition-transform 0.08s ease`
- Refresh Loading: `Loader2` 图标 `animate-spin`（`0.8s linear infinite`）
- Status Card Hover（可选）: `border-border/80`，`transition-colors 0.15s`
- Notice 出现: `fade-in`（opacity `0 → 1`，duration `0.2s`）

**配色应用**
- 卡片背景: `--card`
- 卡片边框: `--border`
- Icon 容器背景: `--muted` 或 `--muted/60`
- Icon 颜色:
  - 正常/信息: `--foreground`
  - 成功（检测到 Claude）: `--success`
  - 错误（未检测到）: `--error`
- Notice 背景:
  - 警告: `hsl(38 85% 52% / 0.08)`，边框 `hsl(38 85% 52% / 0.20)`，文字 `hsl(38 70% 35%)`
  - 错误: `hsl(0 65% 55% / 0.08)`，边框 `hsl(0 65% 55% / 0.20)`，文字 `hsl(0 60% 40%)`
  - 深色模式下 Notice 背景透明度提高至 `0.12`

**Lucide 图标建议**
- `CheckCircle2`（环境正常）
- `XCircle`（环境异常）
- `Wrench`（安装类型）
- `Languages`（当前语言）
- `AlertTriangle`（Notice）
- `RefreshCw`（刷新）
- `Loader2`（刷新中）

---

### 3.2 InstallOptions

**组件选择**
- 外层: shadcn `Card`
- Panel Header: 自定义 flex row
- 语言/模式: shadcn `Select`（非原生 `<select>`）
- 标签: shadcn `Label`
- Checkbox: shadcn `Checkbox`
- 主按钮: shadcn `Button` variant="default"（即 primary）
- 进度提示: 自定义 `div`（`border`, `rounded-md`, `bg-muted/50`）

**内部信息层级**
- Panel Title: `text-base font-medium text-foreground`（14px）
- Select Label: `text-xs font-medium text-muted-foreground uppercase tracking-wide`（11px）
- Select Trigger 文字: `text-sm font-medium`
- Checkbox Label: `text-sm font-medium text-foreground`
- 主按钮文字: `text-base font-semibold`（14px）
- 进度提示文字: `text-xs text-muted-foreground`

**关键交互状态**
- Select Trigger Hover: `border-border/80`
- Select Trigger Focus: `ring-2 ring-primary/20`，`border-primary/50`
- Select Open: 下拉内容 `fade-in + scale-[0.98]→scale-100`（duration `0.12s`）
- Checkbox Checked: `bg-primary border-primary`，勾选图标 `text-primary-foreground`
- 主按钮 Hover: `bg-primary/90`
- 主按钮 Active: `scale-[0.98]`
- 主按钮 Disabled: `opacity-50 cursor-not-allowed`，无 hover 效果
- 主按钮 Loading: 内部 icon + text `fade` 切换，按钮宽度保持不变（避免布局抖动）
- 进度提示出现: `slide-down`（`y: -4 → 0`, opacity `0 → 1`, duration `0.2s`）

**配色应用**
- Card: `--card` 背景，`--border` 边框，`shadow-sm`
- Select Trigger: `--background` 背景，`--input` 边框
- Checkbox: 未选时 `--border`，选中时 `--primary`
- 主按钮: `--primary` 背景，`--primary-foreground` 文字
- 进度提示: `--muted/50` 背景，`--border` 边框

**Lucide 图标建议**
- `Download`（安装按钮）
- `Loader2`（安装中 spinner）
- `Info`（面板标题旁的说明 tooltip，可选）

---

### 3.3 ActionButtons

**组件选择**
- 外层: shadcn `Card`
- Panel Header: 自定义 flex row
- 按钮列表: shadcn `Button` variant="outline" 或 variant="secondary"
- 按钮图标: lucide-react icons

**内部信息层级**
- Panel Title: `text-base font-medium text-foreground`
- 按钮文字: `text-sm font-medium`
- 按钮图标: `18px`，`text-muted-foreground`

**关键交互状态**
- 按钮 Hover: `bg-muted`，`border-border/80`，图标 `text-foreground`
- 按钮 Active: `scale-[0.98]`，`bg-muted/80`
- 按钮 Disabled: `opacity-40`，`cursor-not-allowed`，图标与文字均去色
- 全局 Busy 状态（某一动作执行中）:
  - 非执行中按钮: `opacity-40`，禁用点击
  - 执行中按钮: 显示 `Loader2` 替代原图标，文字变为动作名 + "..."

**响应式变体（760px 宽以下）**
- 按钮布局从垂直列表改为 `2 x 3` 网格（gap `8px`）
- 每个按钮改为 `flex-col items-center justify-center`，高度 `72px`
- 图标放大至 `20px`，文字缩小至 `text-xs`，允许两行

**配色应用**
- Card: `--card` 背景，`--border` 边框
- 按钮: `--secondary` 或 `--background` 背景，`--border` 边框，`--foreground` 文字
- 按钮 Hover: `--muted` 背景

**Lucide 图标建议**
- `RotateCcw`（恢复 / 卸载补丁）
- `CheckCircle2`（允许自动更新）
- `XCircle`（停止自动更新）
- `Wrench`（同步 CC Switch skills）
- `Eraser`（删除 skills 同步）

---

### 3.4 LogPanel

**组件选择**
- 外层: shadcn `Card`
- Panel Header: 自定义 flex row + shadcn `Button`（size="sm", variant="ghost"）
- 日志区域: shadcn `ScrollArea` 包裹 `<pre>` 或 `<div>` 列表
- 分隔: shadcn `Separator`

**内部信息层级**
- Panel Title: `text-base font-medium text-foreground`
- 日志级别标识（如有）: `text-xs font-bold uppercase`，颜色按级别区分
- 日志消息: `text-xs font-mono`（13px），行高 `1.6`
- 时间戳（可选）: `text-xs font-mono text-muted-foreground`
- 操作按钮文字: `text-xs font-medium`

**关键交互状态**
- Copy 按钮 Hover: `bg-muted`
- Clear 按钮 Hover: `bg-destructive/10 text-destructive`
- 复制成功: Sonner toast 提示 "日志已复制"（duration `2000ms`）
- 新日志条目入场: `fade + slide-up`（Framer Motion，`y: 6 → 0`, opacity `0 → 1`, duration `0.18s`）
- 折叠/展开: 点击 Header，`height` 动画 `0.2s ease`

**配色应用（固定暗色，不随系统主题切换）**
- Card 外层: `--card` 背景，`--border` 边框（跟随主题）
- Header: `--card-foreground` 文字，底边框 `--border`
- 日志区域背景: `hsl(220 15% 8%)`（极暗蓝黑，比纯黑柔和）
- 日志文字主色: `hsl(40 10% 82%)`（暖白灰）
- 级别颜色:
  - `info`: `hsl(210 15% 75%)`（淡蓝灰）
  - `warn`: `hsl(38 80% 65%)`（琥珀）
  - `error`: `hsl(0 75% 70%)`（暖红）
- 选中高亮: `hsl(15 58% 59% / 0.15)`（淡橙底）

**Lucide 图标建议**
- `Terminal`（面板标题前缀图标，可选）
- `Clipboard`（复制）
- `Eraser`（清空）
- `ChevronDown / ChevronUp`（折叠展开指示器）

---

## 4. TitleBar 设计

### 4.1 macOS 规格

- **高度**: `28px`
- **背景**: 与 `--card` 同色，底边框 `--border`
- **红绿灯区**: 左侧保留 `70px` 空白，按钮定位:
  - Close: `x: 12px`, `y: 8px`, `size: 12px`
  - Minimize: `x: 28px`, `y: 8px`, `size: 12px`
  - Maximize: `x: 44px`, `y: 8px`, `size: 12px`
- **按钮样式**:
  - 默认: 圆形 `12px`，无边框（或 `1px solid hsl(0 0% 0% / 0.06)`）
  - Close: `bg-[#FF5F57]`
  - Minimize: `bg-[#FEBC2E]`
  - Maximize: `bg-[#28C840]`
  - Hover: 同色系，中心显示符号（`×` / `−` / `+`），符号颜色 `rgba(0,0,0,0.45)`，`font-size: 10px`
- **标题**: "Claude-Zh"，`text-xs font-medium text-foreground/70`，绝对居中于窗口（视觉上忽略红绿灯宽度，但避免与按钮重叠）
- **右侧**: 留空或显示版本号（`text-[10px] text-muted-foreground`，`padding-right: 12px`）
- **拖拽**: 外层容器设置 `data-tauri-drag-region`，红绿灯按钮容器设置 `data-tauri-drag-region="false"`

### 4.2 Windows 规格

- **高度**: `32px`
- **背景**: 与 `--card` 同色，底边框 `--border`
- **左侧内容**:
  - 应用图标: `16px x 16px`，`margin-left: 12px`
  - 应用名: "Claude-Zh"，`text-sm font-medium text-foreground`，`margin-left: 8px`
- **控制按钮区**: 右侧 `138px` 宽（三个按钮各 `46px`）
- **按钮规格**:
  - 尺寸: `46px x 32px`
  - 图标: `16px`
  - Minimize: `minimize2` icon
  - Maximize: `maximize2` icon（或 `square`）
  - Close: `x` icon
- **按钮状态**:
  - Hover（最小化/最大化）: `bg-black/5`（浅色）/ `bg-white/10`（深色）
  - Hover（关闭）: `bg-[#C42B1C] text-white`
  - Active: `opacity-80`
- **拖拽**: 除控制按钮区外全部可拖拽

### 4.3 跨平台统一规则

- 通过 Tauri API 在运行时检测 `platform()`，条件渲染 macOS / Windows TitleBar。
- TitleBar 不随页面内容滚动，始终固定在顶部（`position: absolute; top: 0; left: 0; right: 0; z-index: 50`）。
- 内容区通过 `padding-top: 32px`（或 `28px`）避开 TitleBar。

---

## 5. 关键交互的动效方案（Framer Motion）

### 5.1 主题切换

- **策略**: 无全局过渡动画。
- **实现**: 通过 Rust 端监听系统主题变化，在 HTML `<html>` 元素上立即切换 `.dark` class。
- **防闪烁**: 在 Rust `main.rs` 中，窗口创建前先读取系统主题并注入初始 class，确保 WebView 渲染前主题已确定。
- **CSS**: 所有颜色相关属性（`background-color`, `color`, `border-color`）统一添加 `transition: 0.2s ease`，使系统级切换时产生柔和的跨帧过渡，而非生硬跳变。

### 5.2 安装进度

- **不使用 progress bar**（无确定性百分比）。
- **使用 spinner + 文字**:
  - 图标: `Loader2`，`animate-spin`（`0.8s linear infinite`）
  - 按钮内: icon 与文字 `opacity` 交叉淡入淡出（`AnimatePresence mode="wait"`）
  - 按钮下方: 进度提示条 `slide-down` 入场（Framer Motion `initial={{ opacity: 0, y: -4 }} animate={{ opacity: 1, y: 0 }}`，duration `0.2s`）
- **按钮尺寸锁定**: 安装过程中主按钮宽度保持固定，避免文字长度变化导致布局抖动。

### 5.3 日志条目入场

- **只对最新条目动画**，历史条目不动（避免滚动位置异常）。
- Framer Motion 参数:
  - `initial: { opacity: 0, y: 6 }`
  - `animate: { opacity: 1, y: 0 }`
  - `transition: { duration: 0.18, ease: [0.25, 0.1, 0.25, 1] }`
- 若日志高频连续输出（> 5条/秒），暂停入场动画（直接渲染），避免性能问题。

### 5.4 Toast 入出场（Sonner）

- Sonner 默认动画已足够，无需自定义。
- **统一配置**:
  - 位置: `bottom-right`
  - 间距: `gap-8`（8px）
  - 默认持续时间: `4000ms`
  - 成功 toast: 左侧竖条 `4px` `--success`
  - 错误 toast: 左侧竖条 `4px` `--error`
  - 操作类 toast（如"确认更新"）: duration 设为 `10000ms` 或 `Infinity`

### 5.5 AlertDialog 入场

- **Overlay**: `fade-in`（`opacity: 0 → 1`），duration `0.15s`
- **Content**:
  - `initial: { opacity: 0, scale: 0.97, y: 4 }`
  - `animate: { opacity: 1, scale: 1, y: 0 }`
  - `transition: { duration: 0.2, ease: [0.16, 1, 0.3, 1] }`
- **Exit**: 与入场反向，duration `0.15s`
- **背景模糊**: `backdrop-blur-sm`（`4px`），`bg-black/20`

### 5.6 通用交互规范

| 交互类型 | Duration | Easing | 属性 |
|---|---|---|---|
| Hover 颜色变化 | `0.15s` | `ease` | `background-color`, `color`, `border-color` |
| Active 按压 | `0.08s` | `ease` | `transform: scale(0.97)` |
| Focus Ring | `0s` | — | `box-shadow` 即时出现 |
| 面板/卡片入场 | `0.25s` | `cubic-bezier(0.16, 1, 0.3, 1)` | `opacity`, `y` |
| 列表 stagger | `0.05s` delay / 项 | 同上 | `opacity`, `y` |

---

## 6. 与 Claude.ai 的视觉对标点

### 6.1 主按钮
- **Claude.ai**: 大圆角 pill（如首页 CTA），但在产品 UI（如设置页）中使用 `8px` 圆角，内边距宽裕。
- **对标方案**: 圆角 `radius-md (10px)`，高度 `48px`（主安装按钮）或 `44px`（标准按钮），内边距 `px-6`。字重 `font-semibold (600)`。Hover 时亮度降低而非加深（`bg-primary/90`）。

### 6.2 卡片边框与阴影
- **Claude.ai**: 卡片使用极淡的 `1px` 边框，背景色与页面底色有微妙差异，几乎无阴影。
- **对标方案**: 卡片统一 `1px solid border-border`，背景 `--card`（比 `--background` 稍亮/稍深）。浅色模式加 `shadow-sm`，深色模式去阴影（深色阴影在暗背景下显脏）。

### 6.3 Select / 输入框样式
- **Claude.ai**: Select 触发器有清晰的 `1px` 边框，圆角 `8px`，hover 时边框略深，focus 时带有柔和的外发光。
- **对标方案**: 使用 shadcn `Select`，但覆盖圆角为 `radius-sm (6px)` 或 `radius-md (10px)`。Focus 状态使用 `ring-2 ring-primary/20`，而非默认的 `ring-ring`。

### 6.4 次要文字与标签
- **Claude.ai**: 大量使用 `#6B6B6B`（中灰）作为标签、说明、meta 信息。
- **对标方案**: 标签、副标题统一使用 `text-muted-foreground`（`hsl(240 3% 60%)`），字号 `11px`，`uppercase`，`tracking-wide`，营造克制的信息层级。

### 6.5 页面背景与内容区对比
- **Claude.ai 浅色**: 页面背景 `#FAFAF8`，卡片 `#FFFFFF`。
- **对标方案**: `--background hsl(40 20% 97%)`（约 `#F9F8F6`），`--card hsl(40 20% 99%)`（约 `#FDFCFA`）。差异克制，避免强分割感。

### 6.6 链接与可交互文字
- **Claude.ai**: 橙色作为唯一强调色，链接无下划线，hover 时轻微变暗或出现下划线。
- **对标方案**: 应用内无传统超链接，但主操作色使用 `--primary`。Hover 状态使用 `opacity` 变化或 `brightness`，不使用 `underline`（工具应用中链接极少）。

### 6.7 分隔线
- **Claude.ai**: 使用极淡的分隔线（`#E5E5E5` 级别）。
- **对标方案**: `Separator` 组件使用 `--border/60`（降低不透明度），或直接用 `border-b border-border`。

### 6.8 徽章 / 状态标签
- **Claude.ai**: 小字号 pill 形状，淡背景。
- **对标方案**: Badge 使用 `rounded-full text-xs px-2 py-0.5`，背景 `--secondary`，文字 `--secondary-foreground`。

---

## 7. 必须添加的 shadcn 组件清单

按字母顺序排列：

1. `alert-dialog`
2. `button`
3. `card`
4. `checkbox`
5. `label`
6. `scroll-area`
7. `select`
8. `separator`
9. `sonner`
10. `tooltip`

**安装命令参考**（规格，不执行）：
```text
npx shadcn add alert-dialog button card checkbox label scroll-area select separator sonner tooltip
```

---

## 8. 风险与建议

### 8.1 最小窗口（760 x 620）下的布局风险

- **风险**: ActionButtons 垂直列表在 `620px` 高度下会严重挤压 LogPanel。
- **建议**: 在 `760px` 宽或 `620px` 高下，ActionButtons 从垂直列表切换为 `2 x 3` 图标网格，单按钮高度压缩至 `72px`。通过 CSS Container Query 或 Tailwind `max-h-[620px]` 媒体查询实现。
- **风险**: StatusPanel 的 3 列卡片在 `760px` 下横向空间紧张。
- **建议**: StatusPanel 卡片内文字使用 `truncate` 强制单行省略，平台/架构信息在紧凑模式下隐藏，hover tooltip 显示完整内容。

### 8.2 LogPanel 空间占用过高

- **风险**: 在标准尺寸下 LogPanel `200px` 固定高度会削弱中间操作区的视觉重心。
- **建议**:
  1. **可折叠**: LogPanel Header 添加折叠按钮，默认展开，用户可收起至 `48px` Header 高度。
  2. **动态高度**: LogPanel 高度改为 `flex-1` 占据剩余空间（当总内容未溢出时），避免固定高度导致的死白。
  3. **抽屉模式（远期）**: 如果日志内容极长，考虑将 LogPanel 改为底部抽屉，点击后从底部滑出覆盖操作区。

### 8.3 暗色模式日志面板对比度

- **风险**: 如果日志面板跟随暗色主题使用 `--card` / `--foreground`，warn/error 级别的颜色在深色卡片上对比度不足。
- **建议**: **日志面板强制固定暗色**（`hsl(220 15% 8%)` 背景），无论系统主题为 light 或 dark。原因:
  1. 日志本质是终端输出，固定暗色符合用户心智模型。
  2. 保证 `info/warn/error` 三色在统一暗底上的对比度稳定可控。
  3. 避免主题切换时日志颜色重新计算。
- **对比度数值**: 背景 `hsl(220 15% 8%)`，info 文字 `hsl(210 15% 75%)`（对比度约 `8.2:1`），warn 文字 `hsl(38 80% 65%)`（对比度约 `7.8:1`），error 文字 `hsl(0 75% 70%)`（对比度约 `6.5:1`），均满足 WCAG AA。

### 8.4 无边框窗口的拖拽体验

- **风险**: `data-tauri-drag-region` 若覆盖到可交互元素（如按钮、Select），会导致点击失效。
- **建议**: TitleBar 中的控制按钮（关闭/最小化/刷新）必须用独立容器包裹并显式排除拖拽区域。内容区任何按钮不得与 TitleBar 重叠。

### 8.5 跨平台 TitleBar 高度差异

- **风险**: macOS `28px` 与 Windows `32px` 会导致内容区 `padding-top` 不一致，若硬编码可能遮挡内容。
- **建议**: 通过 Tauri 的 `os.platform()` 在 React 初始化时读取平台，将 TitleBar 高度写入 CSS 变量 `--titlebar-height`。内容区统一使用 `padding-top: var(--titlebar-height)`。

### 8.6 shadcn Select 在 Tauri WebView 中的层叠

- **风险**: shadcn Select 使用 Radix UI Popper，在 Tauri WebView 中若窗口尺寸极小，下拉内容可能被裁切。
- **建议**: 为 Select 的 `position` 设置为 `popper`，并限制 `max-height: 200px`，确保在 `740px` 窗口内不会溢出可视区域。
