/**
 * 运行时平台检测（纯 navigator 判断，无额外依赖）。
 * 在 Tauri WebView / 浏览器中均可使用。
 */

export const isMacOS: boolean =
  typeof navigator !== "undefined" && /Mac/i.test(navigator.platform || navigator.userAgent)

export const isWindows: boolean =
  typeof navigator !== "undefined" && /Win/i.test(navigator.platform || navigator.userAgent)

export const isLinux: boolean =
  typeof navigator !== "undefined" && /Linux/i.test(navigator.platform || navigator.userAgent)

export type Platform = "macos" | "windows" | "linux"

export const platform: Platform = isMacOS ? "macos" : isWindows ? "windows" : "linux"
