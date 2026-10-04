#!/usr/bin/env python3
"""把 zh-CN 词库中新增/未翻译的条目补全到 zh-TW / zh-HK（只填空，不覆盖已有繁体译文）。

用法（在 zh-CN 词库更新后重跑即可同步繁体）:
  python3 scripts/convert_traditional.py

依赖: pip3 install opencc-python-reimplemented

转换策略（不依赖任何硬编码术语表，全部从仓库现有平行译文自动学习）:
  1. 基础转换: OpenCC s2twp（台湾用语）/ s2hk（香港字形）;
  2. 术语校正: 用现有 zh-CN ↔ zh-TW/HK 平行条目做对齐 diff，统计高频词汇差异
     （如 訪問→存取、歸檔→封存），再经"贪心一致性过滤"——每条规则必须让全库
     转换结果与人工译文的完全一致率净提升才保留，防止对齐错位产生的坏规则;
  3. ICU 结构感知: {name} / {n, plural, other {…}} / <tag> 逐层解析，只转换
     纯文本，参数名、类型、selector 等语法部分原样保留；非 ICU 的花括号内容
     （JS 片段等）按纯文本整体转换;
  4. 简体残留检测: 用 OpenCC s2t 逐字判定"简体专用字"，但把现有词库已在使用
     的字（如 s2hk 标准输出的"户"）列入本地白名单，只拦真正的残留;
  5. 填空规则: 已有繁体译文一律保留，只补缺失键和仍是英文原文的条目。
"""
from __future__ import annotations

import difflib
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

try:
    from opencc import OpenCC
except ImportError:
    sys.exit("缺少依赖: pip3 install opencc-python-reimplemented")

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "resources"
S2T = OpenCC("s2t")


class _ChainedCC:
    """组合两个 OpenCC 转换器（用于 HK: 先 s2t 转净简体，再 s2hk 套香港字形）。

    s2hk 自身的字符表有缺口（兑→兌、脱→脫 不转换），链式管线补上，
    同时保留 s2hk 的香港字形偏好（如 戶→户，与现有 HK 词库一致）。"""

    def __init__(self, first, second):
        self.first, self.second = first, second

    def convert(self, s: str) -> str:
        return self.second.convert(self.first.convert(s))


CC = {"zh-TW": OpenCC("s2twp"), "zh-HK": _ChainedCC(OpenCC("s2t"), OpenCC("s2hk"))}

# OpenCC 会把下列字规范成康熙异体字或按方言偏好改写（群→羣、峰→峯、床→牀、
# 游→遊、斗→鬥、托→託、温→溫 等），但台/港标准字形就是常用写法
# （干擾、若干、臨床、游標、漏斗、托特包；s2hk 的香港字形表偏好 户/温），永远放行
EXTRA_WHITELIST = set("群峰床游干斗托温")

# 通用固定修正: 「天后」被 OpenCC 当专名保护（"N 天后失效"应为「天後」）;
# 台/港写「夥伴」; OpenCC 会把"只"(仅)转成量词「隻」; s2hk 把 兌/脫 反转成简化字形
STATIC_RULES_COMMON = {"天后": "天後", "伙伴": "夥伴", "隻": "只", "兑": "兌", "脱": "脫"}
# 各语言术语表：方向全部以仓库现有人工译文的实际用法为准（见各条目的语料计数）。
# TW 主要是抑制 s2twp 的过度本地化（语料用「權限/通過/智能/點擊/發佈/擴展」）;
# HK 主要是补上 s2hk 缺失的词汇层转换（它只做字形，不做 词汇→香港习惯用词）
STATIC_RULES = {
    "zh-TW": {
        "許可權": "權限", "透過": "通過", "文件": "檔案", "聯絡": "聯繫",
        "擴充套件": "擴展", "釋出": "發佈", "智慧": "智能", "優先順序": "優先級",
        "點選": "點擊", "字型": "字體", "整合": "集成", "稽核": "審核",
        "命令列": "命令行", "對話方塊": "對話框", "引數": "參數", "迴圈": "循環",
        "字首": "前綴", "後設資料": "元數據", "執行緒": "線程", "萬用字元": "通配符",
        "激活": "啟用", "階別": "級別", "宣告": "聲明", "解除安裝": "卸載",
    },
    "zh-HK": {
        "登錄": "登入", "服務器": "伺服器", "設置": "設定", "保存": "儲存",
        "支持": "支援", "搜索": "搜尋", "啓": "啟", "羣": "群", "牀": "床",
        "激活": "啟用", "錶": "表", "裏": "裡",
    },
}
# 预掩码：OpenCC 会把下列简体词合并/改写成另一个词（文档→文件、视图→檢視、
# 演示文稿→簡報），转换后无法再区分，须在转换前摘出、转换后按语料写法放回
PRE_MASKS = {"zh-TW": {"文档": "文檔", "视图": "視圖", "演示文稿": "演示文稿"}, "zh-HK": {}}

HAN = re.compile(r"[\u4e00-\u9fff]")
TAG = re.compile(r"</?[A-Za-z][A-Za-z0-9_]*\s*/?>")
ICU_ARG_START = re.compile(r"\{[A-Za-z_][A-Za-z0-9_]*\s*[,}]")
ICU_WITH_ARGS = re.compile(r"\{[A-Za-z_][A-Za-z0-9_]*\s*,")
ASCII_TOKEN = re.compile(r"[A-Za-z0-9]+")
# 简体专用字判定: OpenCC s2t 会改写的 CJK 字。是否放行由各语言白名单决定
# （如 s2hk 的香港标准会把 戶 输出为 户，且现有 HK 词库一致这么用）。
SIMPLIFIED = {chr(cp) for cp in range(0x4E00, 0x9FFF) if S2T.convert(chr(cp)) != chr(cp)}

has_cjk = lambda s: bool(HAN.search(s or ""))


def load(name: str):
    raw = (RES / name).read_text(encoding="utf-8")
    return json.loads(raw), raw


def dump(data) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n"


def find_matching_brace(s: str, i: int) -> int:
    """s[i] == '{'，返回与之配对的 '}' 下标；找不到返回 -1。"""
    depth = 0
    for j in range(i, len(s)):
        if s[j] == "{":
            depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0:
                return j
    return -1


def tokenize(s: str) -> list[tuple[str, str]]:
    """把字符串切成 ('text'/'syntax', 片段) 序列: syntax 原样保留，text 需要转换。"""
    if not ICU_ARG_START.search(s):
        return [("text", s)]  # 无 ICU 参数（花括号是字面量/JS 片段），整体按文本处理
    toks: list[tuple[str, str]] = []

    def emit_text(t: str):
        if t:
            toks.append(("text", t))

    def walk(i: int, end: int):
        while i < end:
            c = s[i]
            if c == "<":
                m = TAG.match(s, i)
                if m:
                    toks.append(("syntax", m.group(0)))
                    i = m.end()
                    continue
                emit_text(c)
                i += 1
            elif c == "{":
                j = find_matching_brace(s[:end] if end < len(s) else s, i)
                if j < 0:
                    emit_text(c)
                    i += 1
                    continue
                walk_arg(i, j)
                i = j + 1
            else:
                k = i
                while k < end and s[k] not in "{<":
                    k += 1
                emit_text(s[i:k])
                i = k

    def walk_arg(ai: int, aj: int):
        """处理一个完整的 {…} ICU 参数组（s[ai]=='{'，s[aj]=='}'）。"""
        inner = s[ai + 1:aj]
        parts, cur, depth = [], [], 0  # 深度 0 处按逗号切: name [, type] [, 其余]
        for c in inner:
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            if c == "," and depth == 0 and len(parts) < 2:
                parts.append("".join(cur))
                cur = []
            else:
                cur.append(c)
        parts.append("".join(cur))
        if len(parts) == 1 or parts[1].strip() not in ("plural", "select", "selectordinal"):
            toks.append(("syntax", s[ai:aj + 1]))  # {name} 或 number/date 等，整段保留
            return
        toks.append(("syntax", "{" + parts[0] + "," + parts[1] + ","))
        i = ai + 1 + len(parts[0]) + 1 + len(parts[1]) + 1  # 跳过 "{name,type,"
        while i < aj:  # 其余部分 = selector/offset 等语法段 与 {分支} 交替
            if s[i] == "{":
                j = find_matching_brace(s, i)
                if j < 0 or j > aj:
                    emit_text(s[i])
                    i += 1
                    continue
                toks.append(("syntax", "{"))
                walk(i + 1, j)
                toks.append(("syntax", "}"))
                i = j + 1
            else:
                k = i
                while k < aj and s[k] != "{":
                    k += 1
                toks.append(("syntax", s[i:k]))
                i = k
        toks.append(("syntax", "}"))

    walk(0, len(s))
    return toks


class Converter:
    """ICU 结构感知转换器: 只转换 text 段。

    术语校正用正则单趟替换（最长源优先），规则之间不会级联;
    最后做"残留清扫": OpenCC 偶发漏转的简体嫌疑字（不在白名单的）按 s2t 单字兜底。"""

    def __init__(self, cc, cmap: dict[str, str] | None = None, fixmap: dict[str, str] | None = None,
                 premask: dict[str, str] | None = None):
        self.cc = cc
        self.cmap = cmap or {}
        self.fixmap = fixmap or {}
        self.premask = premask or {}
        self._re = re.compile("|".join(map(re.escape, sorted(self.cmap, key=len, reverse=True)))) if self.cmap else None
        self._pre = re.compile("|".join(map(re.escape, sorted(self.premask, key=len, reverse=True)))) if self.premask else None

    def flat_text(self, s: str) -> str:
        sent: dict[str, str] = {}
        if self._pre:  # 预掩码: 摘出 OpenCC 会错误合并的词
            def mask(m):
                tok = f"\ue000{len(sent)}\ue001"
                sent[tok] = self.premask[m.group(0)]
                return tok
            s = self._pre.sub(mask, s)
        t = self.cc.convert(s)
        if self._re:
            t = self._re.sub(lambda m: self.cmap[m.group(0)], t)
        for ch, rep in self.fixmap.items():
            if ch in t:
                t = t.replace(ch, rep)
        for tok, form in sent.items():  # 最后放回掩码词，避免被规则表波及
            t = t.replace(tok, form)
        return t

    def __call__(self, s: str) -> str:
        return "".join(self.flat_text(t) if k == "text" else t for k, t in tokenize(s))


def locale_whitelist(values) -> set[str]:
    """现有词库已在(≥2)条目中使用的"简体嫌疑字"视为本库认可的字形，放行。"""
    cnt: Counter = Counter()
    for v in values:
        for ch in set(v):
            if ch in SIMPLIFIED:
                cnt[ch] += 1
    return {ch for ch, c in cnt.items() if c >= 2} | EXTRA_WHITELIST


def learn_corrections(pairs, conv: Converter, banned: set[str]) -> tuple[dict[str, str], float]:
    """从平行译文学习术语校正表，并用贪心一致性过滤剔除坏规则。

    返回 (校正表, 过滤后一致率)。"""
    toks_list = [tokenize(cn) for cn, _ in pairs]
    base_list = [[(k, t if k == "syntax" else conv.flat_text(t)) for k, t in toks] for toks in toks_list]
    base_strs = ["".join(t for _, t in b) for b in base_list]

    def apply_map(basetoks, rx):
        if rx is None:
            return "".join(basetoks)
        return "".join(rx.sub(lambda m: cmap[m.group(0)], t) if k == "text" else t for k, t in basetoks)

    # 候选规则: 与空表基础转换结果做对齐 diff
    cand: dict[str, Counter] = defaultdict(Counter)
    for (cn, real), base_str in zip(pairs, base_strs):
        if len(cn) > 300 or not has_cjk(real) or base_str == real:
            continue
        sm = difflib.SequenceMatcher(None, base_str, real, autojunk=False)
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag != "replace":
                continue
            a, b = base_str[i1:i2], real[j1:j2]
            if len(a) < 2 or len(b) < 2:  # 单字替换交给 OpenCC，学出来极易误伤
                continue
            if not (has_cjk(a) and has_cjk(b)) or re.search(r"[A-Za-z0-9{}\n<>「」『』]", a + b):
                continue
            if SIMPLIFIED.intersection(a) - banned or SIMPLIFIED.intersection(b) - banned:
                continue  # 不学含简体残留的目标词（现有数据自身的笔误）
            cand[a][b] += 1

    candidates = []
    for a, ctr in cand.items():
        total = sum(ctr.values())
        b, c = ctr.most_common(1)[0]
        min_count = 6 if len(a) == 2 else 4
        if c >= min_count and c >= 0.8 * total:  # 主导译法才候选，宁缺毋滥
            candidates.append((c, a, b))
    candidates.sort(key=lambda x: (-x[0], len(x[1])))

    # 贪心一致性过滤: 规则必须让全库与人工译文的完全一致数净增才保留
    cmap: dict[str, str] = {}
    cur = base_strs[:]  # 当前空表下的转换结果
    agree = sum(1 for v, real in zip(cur, (r for _, r in pairs)) if v == real)
    for _, a, b in candidates:
        cmap[a] = b
        rx = re.compile("|".join(map(re.escape, sorted(cmap, key=len, reverse=True))))
        new_agree = 0
        for idx, (cn, real) in enumerate(pairs):
            if a in base_strs[idx]:
                cur[idx] = apply_map(base_list[idx], rx)
            if cur[idx] == real:
                new_agree += 1
        if new_agree > agree:
            agree = new_agree
        else:
            del cmap[a]  # 无净收益，丢弃
    return cmap, agree / len(pairs)


def validate_written(pairs, tag: str, banned: set[str]) -> int:
    """校验本轮写出的条目: ASCII/标签序列不变、ICU 参数签名一致、无简体字残留。"""
    bad = 0
    for cn_v, out_v in pairs:
        problems = []
        leaked = "".join(sorted(banned.intersection(out_v)))
        if ASCII_TOKEN.findall(cn_v) != ASCII_TOKEN.findall(out_v):
            problems.append("ASCII 内容被改动")
        elif TAG.findall(cn_v) != TAG.findall(out_v):
            problems.append("标签序列被改动")
        elif leaked:
            problems.append(f"简体字残留: {leaked}")
        elif cn_v.count("{") != out_v.count("{"):
            problems.append("花括号数不一致")
        elif ICU_WITH_ARGS.search(cn_v):
            s_cn, s_out = parse_icu(cn_v), parse_icu(out_v)
            if s_cn is not None and s_out is not None and s_cn != s_out:
                problems.append("ICU 参数签名不一致")
        if problems:
            bad += 1
            if bad <= 5:
                print(f"    [{tag}][{problems[0]}]\n      cn : {cn_v}\n      out: {out_v}")
    print(f"  校验[{tag}]: 本轮写出 {len(pairs)} 条, 异常 {bad} 条")
    return bad


def parse_icu(s: str) -> str | None:
    """提取 ICU 参数与 <tag> 签名（仅用于带 plural/select 参数的条目）。"""
    args, tags = set(), set()
    i, n = 0, len(s)

    def skip_ws():
        nonlocal i
        while i < n and s[i].isspace():
            i += 1

    def word():
        nonlocal i
        skip_ws()
        b = i
        while i < n and not (s[i].isspace() or s[i] in ",{}"):
            i += 1
        return s[b:i]

    def text(nested):
        nonlocal i
        while i < n:
            c = s[i]
            if c == "'" and i + 1 < n and s[i + 1] == "'":
                i += 2
                continue
            if c == "'" and i + 1 < n and s[i + 1] in "{}":
                e = s.find("'", i + 1)
                if e < 0:
                    raise ValueError
                i = e + 1
                continue
            if c == "{":
                i += 1
                arg()
                continue
            if c == "}":
                if not nested:
                    raise ValueError
                return
            if c == "<":
                m = TAG.match(s, i)
                if m:
                    tags.add(re.sub(r"\s", "", m.group(0)))
                    i = m.end()
                    continue
            i += 1
        if nested:
            raise ValueError

    def arg():
        nonlocal i
        name = word()
        if not name:
            raise ValueError
        args.add(name)
        skip_ws()
        if i < n and s[i] == "}":
            i += 1
            return
        if i >= n or s[i] != ",":
            raise ValueError
        i += 1
        type_ = word()
        skip_ws()
        if i < n and s[i] == "}":
            i += 1
            return
        if i >= n or s[i] != ",":
            raise ValueError
        i += 1
        if type_ in ("plural", "select", "selectordinal"):
            while True:
                skip_ws()
                if i < n and s[i] == "}":
                    i += 1
                    return
                sel = word()
                if not sel:
                    raise ValueError
                if sel.startswith("offset:"):
                    continue
                skip_ws()
                if i >= n or s[i] != "{":
                    raise ValueError
                i += 1
                text(True)
                i += 1
        else:
            d = 1
            while i < n and d:
                if s[i] == "{":
                    d += 1
                if s[i] == "}":
                    d -= 1
                i += 1
            if d:
                raise ValueError

    try:
        text(False)
    except ValueError:
        return None
    return "|".join(sorted(args)) + "#" + "|".join(sorted(tags))


def merge_value(existing: str | None, cn_value: str, conv) -> str:
    """填空规则: 已有繁体译文一律保留; 仍是英文原文且 zh-CN 已有中文时补译;
    双方都不是中文的条目（模板/单位/符号等非译文）跟随 zh-CN 的最新写法;
    新键按 zh-CN 值转换（zh-CN 本身保留英文的条目原样带过去）。"""
    if existing is None:
        return conv(cn_value) if has_cjk(cn_value) else cn_value
    if not has_cjk(existing):
        if has_cjk(cn_value):
            return conv(cn_value)
        return cn_value  # 非译文条目跟随 zh-CN（如排版修正）
    return existing


def fill_dict(cn: dict, tr: dict, conv, label: str, keep_tr_order: bool):
    old = dict(tr)
    out = dict(tr)  # 保留现有键序
    written = []
    for k, v_cn in cn.items():
        if k in out:
            nv = merge_value(out[k], v_cn, conv)
            if nv != out[k]:
                out[k] = nv
                written.append((v_cn, nv))
        else:
            out[k] = merge_value(None, v_cn, conv)
            written.append((v_cn, out[k]))
    if not keep_tr_order:
        # 现有键序与 zh-CN 一致的词表（desktop）: 按 zh-CN 顺序重建, 便于将来 diff
        legacy = {k: v for k, v in out.items() if k not in cn}
        out = {k: out[k] for k in cn}
        out.update(legacy)
    # 零覆盖断言: 原有中文译文一条都不能变
    for k, v in old.items():
        if has_cjk(v):
            assert out[k] == v, f"{label} 已有译文被改动: {k}"
    added = len(out) - len(old)
    filled = len(written) - added
    print(f"  {label}: 新增 {added} 条, 补译英文原文 {filled} 条, 保留原译 {sum(1 for v in old.values() if has_cjk(v))} 条")
    return out, written


def fill_hardcoded(cn: list, tr: list, conv, label: str):
    cn_map = {p[0]: p[1] for p in cn}
    old_map = {p[0]: p[1] for p in tr}
    out = [list(p) for p in tr]
    seen = {p[0] for p in out}
    written = []
    for p in out:
        if p[0] in cn_map:
            nv = merge_value(p[1], cn_map[p[0]], conv)
            if nv != p[1]:
                p[1] = nv
                written.append((cn_map[p[0]], nv))
    for src, v_cn in cn:
        if src not in seen:
            out.append([src, merge_value(None, v_cn, conv)])
            seen.add(src)
            written.append((v_cn, out[-1][1]))
    # 零覆盖断言
    for p in out:
        if has_cjk(old_map.get(p[0], "")):
            assert p[1] == old_map[p[0]], f"{label} 已有译文被改动: {p[0]}"
    added = len(out) - len(tr)
    filled = len(written) - added
    print(f"  {label}: 新增 {added} 对, 补译英文原文 {filled} 对, 保留原译 {sum(1 for v in old_map.values() if has_cjk(v))} 对")
    return out, written


def main():
    cn_fe, _ = load("frontend-zh-CN.json")
    cn_hc, _ = load("frontend-hardcoded-zh-CN.json")
    cn_dt, _ = load("desktop-zh-CN.json")

    targets = {}
    for tag in ("zh-TW", "zh-HK"):
        fe, fe_raw = load(f"frontend-{tag}.json")
        hc, hc_raw = load(f"frontend-hardcoded-{tag}.json")
        dt, _ = load(f"desktop-{tag}.json")
        assert dump(fe) == fe_raw, f"{tag} frontend 词库格式与预期不符（避免整文件重排）"
        assert dump(hc) == hc_raw, f"{tag} hardcoded 词库格式与预期不符"
        targets[tag] = {"fe": fe, "hc": hc, "dt": dt}

    print("== 学习术语风格（从现有平行译文 + 贪心一致性过滤）==")
    converters, banned_map = {}, {}
    for tag, cc in CC.items():
        wl = locale_whitelist(targets[tag]["fe"].values())
        fixmap = {ch: S2T.convert(ch) for ch in SIMPLIFIED - wl}
        print(f"  {tag} 字形白名单: {''.join(sorted(wl)) or '（无）'}")
        pairs_fe = [(v, targets[tag]["fe"][k]) for k, v in cn_fe.items()
                    if k in targets[tag]["fe"] and has_cjk(targets[tag]["fe"][k])]
        cmap, agree = learn_corrections(pairs_fe, Converter(cc, fixmap=fixmap, premask=PRE_MASKS[tag]), wl)
        cmap.update(STATIC_RULES_COMMON)
        cmap.update(STATIC_RULES[tag])
        print(f"  {tag}: 术语校正 {len(cmap)} 条, 现有条目转换一致率 {agree:.1%}")
        print(f"    {'; '.join(f'{a}→{b}' for a, b in sorted(cmap.items(), key=lambda x: -len(x[0])))}")
        converters[tag] = Converter(cc, cmap, fixmap, PRE_MASKS[tag])
        banned_map[tag] = SIMPLIFIED - wl

    total_bad = 0
    for tag in ("zh-TW", "zh-HK"):
        conv = converters[tag]
        banned = banned_map[tag]
        print(f"== 补全 {tag} ==")
        t = targets[tag]
        fe_out, w1 = fill_dict(cn_fe, t["fe"], conv, f"frontend-{tag}", keep_tr_order=True)
        hc_out, w2 = fill_hardcoded(cn_hc, t["hc"], conv, f"frontend-hardcoded-{tag}")
        dt_out, w3 = fill_dict(cn_dt, t["dt"], conv, f"desktop-{tag}", keep_tr_order=False)
        total_bad += validate_written(w1, f"frontend-{tag}", banned)
        total_bad += validate_written(w2, f"frontend-hardcoded-{tag}", banned)
        total_bad += validate_written(w3, f"desktop-{tag}", banned)
        # 抽样预览
        samples = [k for k, v in fe_out.items() if has_cjk(v) and (k not in t["fe"] or not has_cjk(t["fe"][k]))][:5]
        print(f"  抽样[{tag}]:")
        for k in samples:
            print(f"    {cn_fe.get(k, '')!r} -> {fe_out[k]!r}")
        (RES / f"frontend-{tag}.json").write_text(dump(fe_out), encoding="utf-8")
        (RES / f"frontend-hardcoded-{tag}.json").write_text(dump(hc_out), encoding="utf-8")
        (RES / f"desktop-{tag}.json").write_text(dump(dt_out), encoding="utf-8")

    if total_bad:
        sys.exit(f"校验未通过（{total_bad} 条），已中止——文件已写出，请回滚后检查")
    print("== 全部校验通过 ==")


if __name__ == "__main__":
    main()
