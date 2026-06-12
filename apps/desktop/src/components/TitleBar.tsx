import { X, Minus, Maximize2 } from "lucide-react"
import { getCurrentWindow } from "@tauri-apps/api/window"
import { isMacOS } from "@/lib/platform"

/* ─────────────────────────────── 公共 ─────────────────────────────── */

const appWindow = getCurrentWindow()

function handleMinimize() {
  void appWindow.minimize()
}

function handleToggleMaximize() {
  void appWindow.toggleMaximize()
}

function handleClose() {
  void appWindow.close()
}

/* ─────────────────────────────── macOS ─────────────────────────────── */

function MacTitleBar() {
  return (
    <div
      data-tauri-drag-region
      className="relative flex items-center h-[28px] bg-background border-b border-border select-none shrink-0"
    >
      {/* 红绿灯按钮区域 —— 排除拖拽 */}
      <div
        data-tauri-drag-region="false"
        className="absolute left-0 top-0 flex items-center gap-2 pl-3 h-full z-10"
        role="group"
        aria-label="窗口控制"
      >
        <TrafficLight color="#FF5F57" onClick={handleClose} title="关闭">
          <X size={8} strokeWidth={2.5} className="opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity" />
        </TrafficLight>
        <TrafficLight color="#FEBC2E" onClick={handleMinimize} title="最小化">
          <Minus size={8} strokeWidth={2.5} className="opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity" />
        </TrafficLight>
        <TrafficLight color="#28C840" onClick={handleToggleMaximize} title="最大化">
          <Maximize2 size={7} strokeWidth={2.5} className="opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity" />
        </TrafficLight>
      </div>

      {/* 标题 —— 绝对居中 */}
      <span className="absolute inset-0 flex items-center justify-center text-xs font-medium text-foreground/70 pointer-events-none">
        Claude-Zh
      </span>
    </div>
  )
}

/** 单个红绿灯圆点 */
function TrafficLight({
  color,
  onClick,
  title,
  children,
}: {
  color: string
  onClick: () => void
  title: string
  children: React.ReactNode
}) {
  return (
    <button
      type="button"
      title={title}
      aria-label={title}
      onClick={onClick}
      className="group relative w-3 h-3 rounded-full border border-black/[0.06] flex items-center justify-center transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1"
      style={{ backgroundColor: color }}
    >
      <span className="text-black/45" style={{ fontSize: 10, lineHeight: 1 }}>
        {children}
      </span>
    </button>
  )
}

/* ─────────────────────────────── Windows ─────────────────────────────── */

/**
 * Windows 平台使用原生窗口装饰（标题栏 + 控制按钮）。
 *
 * WebView2 在 Windows 无边框模式（decorations: false）下存在
 * 渲染管线限制：自绘 HTML 内容在客户端区域仅左侧 ~100px 可见，
 * 右侧大面积不可见（经 BitBlt 像素验证确认）。
 *
 * 回退方案：在 lib.rs setup hook 中调用 set_decorations(true)
 * 启用原生标题栏，此组件返回 null 不渲染自绘 TitleBar。
 * macOS 保持无边框 + 自绘红绿灯。
 */
function WinNativeTitleBar() {
  return null
}

/* ─────────────────────────────── 入口 ─────────────────────────────── */

export function TitleBar() {
  return isMacOS ? <MacTitleBar /> : <WinNativeTitleBar />
}
