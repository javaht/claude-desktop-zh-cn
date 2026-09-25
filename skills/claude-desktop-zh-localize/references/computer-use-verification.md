# Computer Use 视觉回归验证手册

用 ZCode 的 computer-use 能力打开打完补丁的 Claude Desktop，逐页截图核对汉化效果。适用于：批量新增词条并重新安装补丁之后，或用户报告"某页面还是英文"需要定位时。

## 0. 一次性前置条件（只能由用户完成）

1. **辅助功能（Accessibility）+ 屏幕录制（Screen Recording）** 必须授予 `ZCode Computer Use.app`：
   系统设置 → 隐私与安全性 → 辅助功能 / 屏幕录制 → 勾选 `ZCode Computer Use.app`。
2. 授权后**完全退出并重启 ZCode**，让它重启 Helper 重新读取 TCC 授权。

出现以下任一错误即说明权限未就绪，直接停下请用户授权，**不要**改用 AppleScript 等其他自动化技术绕过：

- `permission broker request capture_app timed out after 15000ms`
- `capture_app: the target app has no readable accessibility tree ...`
- `Accessibility not granted to ZCode.app ...`

注意：即使未授权，`listApps()` 仍能返回应用列表（走的是非辅助功能路径），不要据此误判权限已通过。

## 1. 准备

- 确认补丁已安装到 `/Applications/Claude.app`（改过 `resources/` 之后必须重跑 `scripts/patch_claude_zh_cn.py`，约 5 分钟；补丁会自动退出并重开 Claude）。
- 确认 Claude 进程在跑：`pgrep -fl "Claude.app/Contents/MacOS"`；不在则 `open -a Claude`。
- `en-US.json` 参考路径：`/Applications/Claude.app/Contents/Resources/ion-dist/i18n/en-US.json`。

## 2. 引导与绑定

每次 `mcp__node_repl__js` 调用都是全新 Worker，**每次调用都要以同一段 bootstrap 开头**：

```js
const root =
  process.env.ZCODE_CUA_PLUGIN_ROOT ??
  process.env.ZCODE_PLUGIN_ROOT ??
  process.env.CLAUDE_PLUGIN_ROOT;
const { join } = await import("node:path");
const { pathToFileURL } = await import("node:url");
const { setupComputerUseRuntime } = await import(
  pathToFileURL(join(root, "scripts", "computer-use-client.mjs")).href,
);
await setupComputerUseRuntime({ globals: globalThis });

const app = await agent.computerUse.getApp("Claude");
await app.getAXStateAndScreenshot();   // 绑定后先观察一次
```

要点（来自 2026-09 实测）：

- **辅助功能树可读性不稳定**：主窗口（新建任务页）往往只暴露 28 个左右的壳层 group，读不到网页文本；进入设置后则能暴露完整文本树（几百个 text 元素，含每个设置项的中文文案）。**判定语言以截图为准，导航优先用元素 index**（设置侧边栏的每项都是可 `AXPress` 的 button）。
- `getAXStateAndScreenshot()` 会自行展示截图，一次调用只出一张图，不要把返回值再 `emitImage`。
- 坐标只能取自**当前返回的截图**（`0 <= x < width`），禁止复用旧的元素/窗口 bounds。
- 观察调用自带等待 UI 稳定，不要 `setTimeout` 或轮询；连续观察无变化时先做一个动作再观察。
- 树默认按 diff 返回（只列变化项，未变项 index 仍有效）；需要全量树时传 `{ disableDiffing: true }`。

## 2.5 实测可行的操作序列

```js
// 1) 绑定 + 首次观察（主窗口）
const app = await agent.computerUse.getApp("Claude");
await app.getAXStateAndScreenshot();

// 2) 打开设置
await app.pressKey("cmd+,");
await app.getAXStateAndScreenshot();

// 3) 点设置侧边栏某项（index 取自最近一次观察，如"偏好设置"=50、"隐私"=52、
//    "Claude Code"=56、"技能"=72、"插件"=76——以实际树为准）
await app.click(50);
await app.getAXStateAndScreenshot();

// 4) 关闭设置
await app.pressKey("Escape");
```

注意 index 会随树刷新而变，每次点击前以最新一次观察为准；上一轮的 index 在 diff 观察中通常仍然有效。

## 3. 逐页核对清单

打开设置：对绑定的 app `await app.pressKey("cmd+,")`（或点左下角账号菜单 → 设置）。每页一张 `getAXStateAndScreenshot()`，按此清单核对（✓ = 本次会话补过的典型词条）：

| 设置页 | 核对点 |
| --- | --- |
| 偏好设置（一般） | 主题 / 聊天字体 / 动态效果 / 语音(语言下拉应为"中文（普通话）"，展开应见"英语""粤语"等) / 回复完成 / 工具访问模式 / 按需加载工具 / 当消息被标记时切换模型 |
| 帐号 | 组织 ID / 从所有设备退出登录 / 删除你的账号 / Claude 指令整句中文（含"Anthropic 准则"链接） |
| 隐私 | 我们如何保护你的数据 / 偏好设置 / 位置元数据 / 你的数据 / 导出数据 / 已分享的聊天 |
| 计费 | 升级计划 / 发票 |
| 记忆 | 从聊天中生成记忆 / 在记忆中包含敏感主题 / "已迁移至新的记忆系统…剩余 N 天可[导出旧版记忆]"横幅 |
| 时间与专注 | 时间与专注子项 |
| Claude Code | 常规 / 分类会话状态 / 代码外观 / Claude 浅色 / 代码字体 / 本地沙箱 / 严格沙箱模式 / 浏览器工具 / 保留 Cookie(选项"直到退出") / 归档不活动的会话 / 使用电池电量时保持唤醒 |
| 系统 | 桌面应用版本 / 听写快捷方式 / 保持计算机处于唤醒状态 |
| 扩展 / 开发者 | 编辑配置 / 导入与导出 / "当前部署未启用导入功能…" |
| 技能 | 搜索技能和插件(占位符) / 添加下拉: 上传技能 / 创建技能 / 用 Claude 创建 / 添加你的第一批技能 |
| 插件 | 你的插件 / 全部插件 / 排序 · 最近编辑 / 添加你的第一批插件 |
| 连接器 | 发现 / 添加你的第一批连接器 |

主窗口侧边栏（Escape 关掉设置后核对）：聊天与任务 / 项目 / 技能 / 连接器 / 插件 / 新建分组… / 右键菜单(固定 / 重命名 / 归档 / 移至组) / 悬停"隐藏侧边栏 ⌘ B"。

项目页：新建项目 / 想要开始一个项目？/ 最近更新 / 按类型分组；计划任务页：计划任务 / 新建任务下拉(用 Claude 创建 / 手动设置)。

## 4. 判定与回报

- 每页结论只写 `PASS` / `FAIL + 具体英文残留原文`；截图即证据。
- 发现英文残留 → 回到主工作流第 1 步定位 key → 补词表/正则 → 重打补丁 → 只复验失败页。
- 全部通过后向用户汇总一页对照表（页面 / 检查点 / 结果）。

实测发现 FAIL 的处理实例（2026-09）：Claude Code 页「需要注意时提醒我」的描述仍是英文 → 在 a11y 树中直接读到原文 `Bounce the Dock icon when Claude needs your attention and the app isn't focused.` → 在 en-US.json 反查得 key `HOH5mdam48` → 按主工作流补三地词表 → 重打补丁后仅复验该页。设置页的 a11y 树能直接给出完整英文原句，比截图抄写更可靠，优先用它。

## 5. 常见坑（均实测踩过）

- **Electron 后台窗口的 webview 树会挂起**：配置窗口失焦后 a11y 树只剩约 27 个壳层元素，按坐标的点击/键盘事件全部无效（作用于真实指针位置）。对策：观察（getAXState with disableDiffing 或 elements()）会重新唤醒 webview 树；唤醒后用**元素 index**（AXPress）点击，它在后台窗口依然有效。点击前必须以最新一次观察的 index 为准，旧 index 会报 "tree has shifted"。窗口偶发白屏：等待数秒并重复观察即可加载；卡死时关闭重开。

- **配置窗口与主窗口首页走 react-intl 语言包，不走 DOM 注入**：只写硬编码词表在这些界面不生效，必须同时写 `frontend-zh-*.json` 的 key（详见 SKILL.md 第 3 步）。判定某句"该走哪条通道"的最快办法：改完后观察是否渲染，不渲染 = 缺 key。
- **长页是虚拟化渲染，折叠区下方读不到**：a11y 树只含可视区域条目，合成滚动在后台窗口无效。对策：不做逐页滚动，改从 en-US.json 按 **key 命名簇**兜底扫描（如 `Ssh*`、`c4g*`、`Inf*`、`Config*`、`Relaunch*`、`scheduledTasks*`、`keepAwake*`、`CodeRepo*`、`InfIdp*`）+ 关键词值搜索（"SSH"、"built-in browser"、"Organization instructions" 等），把整个配置簇一次挖全。注意按前缀匹配会捞进无关散键（如 `Vm*` 随机哈希键、PR 评审动作），按语义过滤。
- **3p 配置的 locale 竞态（重要）**：应用启动时会把 `~/Library/Application Support/Claude-3p/config.json` 的 `locale` 归一化为系统语言（en-US）。**绝不在应用运行时手改该文件**——会被运行中的应用回写覆盖。修正顺序必须是：杀掉应用 → 改 locale → 启动。若界面整体回退英文，最可靠的恢复方式是**重跑补丁脚本**（它会优雅退出、写入双配置 locale、刷新 DesktopIntl 锁后重启），而不是手工编辑。
- **`pkill -9` 的连锁后果**：强杀后应用可能无窗口启动（`list_windows` 返回 `[]`，`claude://` 与 reopen 事件唤不回）；连续强杀还可能令 Helper 的 TCC 授权状态失效（报 "Accessibility not granted"，需重启 ZCode）。能用补丁脚本的优雅退出（quit_claude）就不要 -9。
- **应用可能自动更新**：多轮重启期间 Claude 可能自更新，asar 主 bundle 文件名会变（如 `index.chunk-D3OyLXgG.js` → `DzZc-q0x.js`）。补丁脚本会自适应，但重打补丁后要以新 bundle 名核验。
- **代码演示区保持英文是正确的**：Claude Code 页"代码外观"里的 `function greet...` 代码块被保护选择器（`pre,code,[data-language]` 等）排除在翻译之外，不是漏翻。
- **设置是 claude.ai 在线页**：DOM 翻译脚本在 `dom-ready` 注入，首次打开偶见先英文后翻成中文的闪变，截图前让观察调用自行等稳即可；仍残留再判 FAIL。
- **需要登录**：未登录时在线页不可达，只能验证侧边栏与本地壳层，报告中注明。
- **补丁刚装完语言可能回 English**：左下角账号菜单 → Language → 简体中文（补丁已锁 `spa:locale`，正常不会发生）。
- **弹窗/对话框**：观察结果的 `window` 字段会变，先读弹窗内容再决定处理或 Escape 关闭。
- **误点风险**：帐号页有"删除账号"红按钮、右键菜单有"删除"，核对时**只看不点**；确实要展开菜单就点无副作用项。
- **asar 内容按 unicode 转义存储**：注入脚本经 `json.dumps`（ensure_ascii=True）写入 asar，中文以 `\uXXXX` 形式存在。直接按中文原文 `in asar_bytes` 搜不到，要用 `s.encode("unicode_escape")` 复核。
