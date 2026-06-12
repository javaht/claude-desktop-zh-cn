import { useEffect, useState } from "react"

type Theme = "light" | "dark"

/**
 * 跟随系统主题自动在 <html> 上切换 "dark" class。
 * 只读 —— 不提供手动切换能力，应用决定跟随系统。
 */
export function useTheme(): { theme: Theme } {
  const [theme, setTheme] = useState<Theme>(() => {
    if (typeof window !== "undefined" && window.matchMedia("(prefers-color-scheme: dark)").matches) {
      return "dark"
    }
    return "light"
  })

  useEffect(() => {
    const mq = window.matchMedia("(prefers-color-scheme: dark)")

    function sync(e?: MediaQueryListEvent) {
      const isDark = e ? e.matches : mq.matches
      setTheme(isDark ? "dark" : "light")
      document.documentElement.classList.toggle("dark", isDark)
    }

    // 初始化时立即同步一次，覆盖 inline script 可能留下的状态
    sync()

    mq.addEventListener("change", sync)
    return () => mq.removeEventListener("change", sync)
  }, [])

  return { theme }
}
