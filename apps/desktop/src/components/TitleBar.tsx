import { useState } from "react"
import { X, Minus, Maximize2 } from "lucide-react"
import { getCurrentWindow } from "@tauri-apps/api/window"
import { isMacOS } from "@/lib/platform"
import { cn } from "@/lib/utils"

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
      className={cn(
        "relative flex items-center h-[28px] bg-background border-b border-border select-none shrink-0"
      )}
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
  const [hovered, setHovered] = useState(false)

  return (
    <button
      type="button"
      title={title}
      aria-label={title}
      onClick={onClick}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      className="group relative w-3 h-3 rounded-full border border-black/[0.06] flex items-center justify-center transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1"
      style={{ backgroundColor: color }}
    >
      {hovered && (
        <span className="text-black/45" style={{ fontSize: 10, lineHeight: 1 }}>
          {children}
        </span>
      )}
    </button>
  )
}

/* ─────────────────────────────── Windows ─────────────────────────────── */

function WinTitleBar() {
  return (
    <div
      data-tauri-drag-region
      className={cn(
        "relative flex items-center h-8 bg-background border-b border-border select-none shrink-0"
      )}
    >
      {/* 左侧应用名 */}
      <span className="ml-3 text-sm font-medium text-foreground pointer-events-none">
        Claude-Zh
      </span>

      {/* 右侧控制按钮 —— 排除拖拽 */}
      <div
        data-tauri-drag-region="false"
        className="absolute right-0 top-0 flex items-center h-full"
      >
        <WinButton onClick={handleMinimize} title="最小化">
          <Minus size={16} />
        </WinButton>
        <WinButton onClick={handleToggleMaximize} title="最大化">
          <Maximize2 size={14} />
        </WinButton>
        <WinButton onClick={handleClose} title="关闭" isClose>
          <X size={16} />
        </WinButton>
      </div>
    </div>
  )
}

function WinButton({
  onClick,
  title,
  isClose = false,
  children,
}: {
  onClick: () => void
  title: string
  isClose?: boolean
  children: React.ReactNode
}) {
  return (
    <button
      type="button"
      title={title}
      aria-label={title}
      onClick={onClick}
      className={cn(
        "w-[46px] h-8 flex items-center justify-center text-foreground transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1",
        isClose
          ? "hover:bg-destructive hover:text-destructive-foreground"
          : "hover:bg-muted"
      )}
    >
      {children}
    </button>
  )
}

/* ─────────────────────────────── 入口 ─────────────────────────────── */

export function TitleBar() {
  return isMacOS ? <MacTitleBar /> : <WinTitleBar />
}
