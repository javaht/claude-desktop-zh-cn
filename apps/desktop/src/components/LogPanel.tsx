import { useEffect, useRef } from "react";
import { motion } from "framer-motion";
import { Copy, ScrollText, Terminal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { toast } from "sonner";
import { useReducedMotion } from "../lib/motion";
import type { LogEvent } from "../types";

type LogPanelProps = {
  logs: LogEvent[];
  logText: string;
  onCopy: () => Promise<unknown> | void;
};

function levelColor(level: string) {
  if (level === "error") return "text-red-400";
  if (level === "warn") return "text-yellow-400";
  return "text-gray-300";
}

export function LogPanel({ logs, logText, onCopy }: LogPanelProps) {
  const logEndRef = useRef<HTMLDivElement | null>(null);
  const reduced = useReducedMotion();

  const hasError = logs.some((l) => l.level === "error");

  useEffect(() => {
    logEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [logs]);

  const handleCopy = async () => {
    try {
      await onCopy();
      toast.success("日志已复制");
    } catch {
      toast.error("复制失败", { description: "请检查剪贴板权限" });
    }
  };

  return (
    <div className="flex flex-col rounded-md border bg-card text-card-foreground">
      {/* Header - always visible, 36px, 固定显示 + 仅复制按钮 */}
      <div className="flex items-center justify-between h-8 px-2 bg-muted/40 select-none">
        <div className="flex items-center gap-1 text-[11px] font-medium">
          <Terminal className="h-2.5 w-2.5 text-muted-foreground" />
          <span>执行日志</span>
          <span className={`text-[10px] ${hasError ? "text-destructive font-medium" : "text-muted-foreground"}`}>
            · {logs.length}
          </span>
        </div>
        <div className="flex items-center gap-0.5">
          <Button
            variant="ghost"
            size="icon"
            className="h-5 w-5"
            onClick={handleCopy}
            title="复制日志"
          >
            <Copy className="h-3 w-3" />
          </Button>
        </div>
      </div>

      {/* 固定高度 140px 的日志区 - 不再可折叠 */}
      <div className="h-[140px]" style={{ background: "hsl(220 15% 8%)" }}>
        <ScrollArea className="h-full">
          <div className="font-mono text-[10.5px] leading-relaxed p-2 h-full">
            {logs.length === 0 ? (
              <motion.div
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                transition={{ duration: reduced ? 0 : 0.2 }}
                className="flex flex-col items-center justify-center h-[100px] gap-1"
              >
                <ScrollText className="h-3.5 w-3.5 text-muted-foreground/60" />
                <span className="text-[10px] text-muted-foreground">暂无日志</span>
              </motion.div>
            ) : (
              logs.map((log, i) => (
                <div
                  key={i}
                  className={`${levelColor(log.level)} py-0.5`}
                >
                  {log.message}
                </div>
              ))
            )}
            <div ref={logEndRef} />
          </div>
        </ScrollArea>
      </div>
    </div>
  );
}
