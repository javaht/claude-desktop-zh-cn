import type { Language, PatchMode } from "./types";

export const languages: Array<{ value: Language; label: string }> = [
  { value: "zh-CN", label: "简体中文" },
  { value: "zh-TW", label: "繁体中文（台湾）" },
  { value: "zh-HK", label: "繁体中文（香港）" },
];

export const modes: Array<{ value: PatchMode; label: string }> = [
  { value: "safe", label: "第三方 API" },
  { value: "official", label: "官方账号登录" },
];
