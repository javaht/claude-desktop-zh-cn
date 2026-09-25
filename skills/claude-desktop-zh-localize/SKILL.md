---
name: claude-desktop-zh-localize
description: 为 claude-desktop-zh-cn 项目补全 Claude Desktop 未汉化界面。当用户发来 Claude Desktop 界面截图并指出未翻译的英文（如"这些没汉化"、"帮我汉化一下"），或要求为新版 UI 增加简体/繁体中文翻译时立即使用。覆盖 i18n 键值词表、硬编码词表与 DOM 动态正则三层，并自动验证映射命中率。
---

# Claude Desktop 中文补丁 · 汉化工作流

本项目是 Claude Desktop 的本地中文补丁。界面文本通过三层机制汉化，新增翻译时必须按目标文本的性质选择正确的层，三层全部落位后统一验证。

## 三层汉化机制

| 层 | 文件 | 作用范围 |
| --- | --- | --- |
| 1. i18n 键值词表 | `resources/frontend-zh-{zh-CN,zh-TW,zh-HK}.json` | 走 react-intl 的标准组件。合并进应用的 `zh-*.json`，有 key 即原生显示中文 |
| 2. 硬编码词表 | `resources/frontend-hardcoded-zh-*.json`（`[源文, 译文]` 二元组列表） | 未走 i18n 的前端 bundle 文本（安装时静态替换 JS），同时并入在线 DOM 翻译映射 |
| 3. DOM 动态正则 | `scripts/patch_claude_zh_cn.py` 的 `build_online_dom_translation_script()` 中 `G=[...]` 数组；Windows 同款模板在 `scripts/install_windows.ps1` | 动态文本：计数、日期、时间区间、带变量的句子。**两个引擎必须同步修改** |

桌面壳层文本（极少）放 `resources/desktop-zh-*.json`。

## 工作流

### 第 1 步：定位 i18n key

在已安装应用的英文语言包中按值精确匹配（项目词表只保留当前版本存在的 key）：

```python
import json
en = json.load(open("/Applications/Claude.app/Contents/Resources/ion-dist/i18n/en-US.json"))
for text in ["Theme", "Chat font"]:
    print(text, {k for k, v in en.items() if v == text})
```

- 精确匹配不到时用小写子串模糊搜索，并去前端 bundle（`/Applications/Claude.app/Contents/Resources/ion-dist/assets/v1/*.js`）里确认组件写法。
- 截图里的文本往往是多个 DOM 节点拼出来的（链接前后各一个 text node），要分别找。

### 第 2 步：确定三地译文

zh-CN / zh-TW / zh-HK 各写一份，遵守下方术语表。同一个英文值若有多个 key，全部都要写。

### 第 3 步：写入词表

**关键机制（实测踩坑后确认）**：配置窗口（配置第三方推理）和主窗口首页走 **react-intl + 语言包 key**，DOM 注入层对它们无效！因此每条翻译必须**同时**写入：

1. `frontend-zh-*.json`（**必须有 key**——在 `en-US.json` 里按值反查；只写硬编码对在该窗口不生效）；
2. `frontend-hardcoded-zh-*.json`（覆盖在线 DOM 层与本地 bundle 静态替换）。

用脚本一次性更新三个 `frontend-zh-*.json`（dict，`key: 译文`）和三个 `frontend-hardcoded-zh-*.json`（list of `[source, target]`）。硬编码词表注意：

- **弯引号与直引号各写一条**（`can't` 与 `can't` 是两个不同源串）；
- **链接前后拆分的文本节点**，前导节点要写"带尾随空格"和"不带"两条，例如 `"...within Anthropic's guidelines. Learn more"` 的前半句 `Claude will keep these in mind ... within ` 需单独成条；
- **被 `<code>` 片段拆开的句子**（如 "when `enabled` is true"）：key 的译文直接含反引号整体翻译（`` "当 `enabled` 为 true 时……" ``），DOM 层则需按静态分段逐段映射；
- **CSS 大写显示的标题**（如页面显示 `NETWORK PROXY`）实际 key 值可能是 `Network proxy`，按 key 原值匹配；
- 源文与译文相同的条目会被丢弃（见陷阱 1），不能"原样保留"。

### 第 4 步：动态文本写正则规则

凡含数字/日期/变量的句子（`Delete 3 chats?`、`Updated Aug 19`、`Past 3 months`）不能靠静态映射，必须在**两处**同步加规则：

1. `scripts/patch_claude_zh_cn.py`：在 `build_online_dom_translation_script()` 的 `G=[...]` 数组加 `[/^...$/,"译文 $1"]`；可变的措辞先在函数开头的 `if lang_code == "zh-CN": / else:` 分支里定义文本变量。
2. `scripts/install_windows.ps1`：`$template = @'...'@` 模板中加同款规则；新文本变量走 `__PLACEHOLDER__` 占位符——(a) 在模板首行 `const L=...,XXX=__XXX__;` 声明；(b) 在函数体用 `$xxxText = if ($Language -eq "zh-CN") { "...`$1..." } else { "..." }` 定义（PowerShell 双引号串中 `$1` 要写成 `` `$1 ``）；(c) `ConvertTo-Json -Compress` 后追加到函数末尾的 `.Replace("__XXX__", $xxxTextJson)` 链。

写完正则先用 Node 快速验证匹配：

```bash
node -e 'const G=[[/^Past (\d+) months?$/,"过去 $1 个月"]];for(const s of ["Past 3 months","Past 1 month"]){const m=s.match(G[0][0]);console.log(s,"->",m?G[0][1].replace("$1",m[1]):"NO MATCH")}'
```

### 第 5 步：验证

```bash
# 三地映射命中 + 废弃键检查（有未命中即退出码 1）
python3 skills/claude-desktop-zh-localize/scripts/verify_mapping.py "Theme" "Past 3 months" ...

# 语法检查
python3 -m py_compile scripts/patch_claude_zh_cn.py scripts/patch_linux_asar.py
```

`verify_mapping.py` 默认读 `/Applications/Claude.app`，可用 `CLAUDE_APP=/path/to/Claude.app` 覆盖。需要端到端确认时再跑 `python3 scripts/patch_claude_zh_cn.py --user-home "$HOME" --dry-run`（约 5 分钟，非必需）。

### 第 6 步：Computer Use 视觉回归验证（可选但推荐）

用户要求"测试页面"、"看看汉化效果"，或批量补词之后需要真机确认时执行：重跑安装脚本把词表打进 `/Applications/Claude.app`，再用 computer-use 逐页截图核对。完整分步手册（含权限前置条件、bootstrap 代码、逐页核对清单、判定标准）见 **`references/computer-use-verification.md`**，执行前必读。

### 第 7 步：提交

默认不主动提交；用户要求提交时：从 `main` 切 `feat/...` 分支 → `git add resources scripts` → commit（`feat: ...`）→ push → `gh pr create` → 报告 PR 链接，等用户确认后再 merge。

## 陷阱清单（都真实踩过）

1. **源文 == 译文的条目会被静默丢弃**。`is_online_dom_translation_entry()` 要求 `source != target`，所以 "Pull requests" 这类想保留英文的词必须给出真译文（如"拉取请求"）。
2. **含 `{` 或换行的文本进不了 DOM 映射**（长度上限 1000）。ICU 复数串如 `{count, plural, ...} will be permanently deleted` 只能写进硬编码词表（对本地 bundle 生效），在线 DOM 侧必须配正则：`[/^(\d+) items? will be permanently deleted\./, ...]`。
3. **DOM 文本节点会在链接处被拆开**，整句静态映射匹配不上。处理方式见第 3 步的前导节点变体。
4. **macOS 与 Windows 引擎必须同步**。只改 Python 不改 ps1，Windows 在线页面会漏翻；反之亦然。
5. **不要往 `frontend-zh-*.json` 写 en-US.json 里不存在的 key**——合并时会被忽略并计入 `extra old keys`，验证要求该值恒为 0。
6. **硬编码词表是 dict 合并语义**（后写覆盖同源文），重复添加无害，但弯/直引号、带不带空格是不同 key。
7. **⚠️ 通用单词/数据标识符严禁进硬编码词表**。硬编码替换会命中 JS 源码里该词的**所有**带引号出现，包括数据上下文。真实事故：`"Pin"→固定` 把 `icon:"Pin"` 图标名改成中文（图标全坏）；`"Engineering"→工程` 把 `workFunction:"Engineering"` 服务端数据值和 `Ax=["...",...]` 角色数组改掉，与未替换的 unquoted 对象键 `Engineering:[...]` 失配 → `f["工程"]` undefined → 连接器页崩溃（`TypeError: e is not iterable`）。判定规则：**单词若同时是 (a) 图标/组件名、(b) 服务端数据值、(c) 对象键/switch-case/数组元素，就绝不能进硬编码词表**——改用 react-intl key（frontend-zh-*.json）提供翻译。若已发生污染：在 `ion-dist/assets/v1/*.js` 中把 `"中文"` 批量还原为英文原词（UI 显示由 intl catalog 提供，不受影响），**不要碰 app.asar（M 映射的键值对是合法的）与 i18n catalog**。
8. **主进程菜单翻译自 2.9939.2 起改走 desktop 语言包（intl catalog）**：菜单缺失翻译时应用会把 `Missing message: "<id>" ... (default message (英文)) as fallback` 打到 stderr——前台启动应用收集该日志即可拿到完整的未翻译菜单 key 清单（71 个），写入 `desktop-zh-*.json` 后由 `install_desktop_locale` 合并进 `Contents/Resources/zh-CN.json`。
9. **⚠️ 2.9939.2（Electron 44）两大挂死**：`patch_online_locale_lock`（DesktopIntl 锁，任何形态包括可重入标志位）与菜单运行时补丁都会让主进程在菜单构建后、窗口创建前陷入 JS 深度递归——进程活着但永远无窗口、AX 超时。两者都已加版本门控（`>= 2.9939.2` 跳过注入），新版菜单由 desktop 语言包覆盖。若需诊断：`sample <pid>` 看主线程是否陷入 JS 深度递归（成千层重复栈帧）。
10. **应用启动时会把 `Claude-3p/config.json` 的 locale 归一化为系统语言**。修 locale 的正确顺序：杀应用 → 改配置 → 启动；运行时改会被回写覆盖。界面整体回退英文时重跑补丁脚本即可。
11. **手工 `codesign --force --deep --sign -` 会清空 entitlements**（丢失 `com.apple.security.virtualization`），导致补丁校验失败。必须用补丁自带的 `resign_app`（从原二进制读取并保留授权），或从最近一个由补丁签名的备份恢复。

## 术语对照表

| 英文 | zh-CN | zh-TW | zh-HK |
| --- | --- | --- | --- |
| session | 会话 | 工作階段 | 工作階段 |
| project | 项目 | 專案 | 項目 |
| data | 数据 | 資料 | 數據 |
| file / folder | 文件 / 文件夹 | 檔案 / 資料夾 | 檔案 / 資料夾 |
| settings | 设置 | 設定 | 設定 |
| default | 默认 | 預設 | 預設 |
| plugin / skill | 插件 / 技能 | 外掛程式 / 技能 | 插件 / 技能 |
| import / export | 导入 / 导出 | 匯入 / 匯出 | 匯入 / 匯出 |
| sign out | 退出登录 | 登出 | 登出 |
| account | 账号 | 帳號 | 帳戶 |
| archive | 归档 | 封存 | 封存 |
| group | 分组 | 群組 | 分組 |
| token | 令牌 | 權杖 | 權杖 |
| memory | 记忆 | 記憶 | 記憶 |
| sandbox | 沙箱 | 沙箱 | 沙箱 |
| create | 创建 | 建立 | 創建 |
| rename | 重命名 | 重新命名 | 重新命名 |
| sidebar | 侧边栏 | 側邊欄 | 側邊欄 |
| learn more | 了解更多 | 深入了解 | 了解更多 |

不确定的术语先在现有词表里 `grep` 既有译法，保持一致优先。
