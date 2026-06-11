import { useEffect, useRef } from "react";
import { motion } from "framer-motion";
import { Copy, Eraser, ScrollText, Terminal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { ScrollArea } from "@/components/ui/scroll-area";
import { toast } from "sonner";
import { useReducedMotion } from "../lib/motion";
import type { LogEvent } from "../types";

type LogPanelProps = {
  logs: LogEvent[];
  logText: string;
  onCopy: () => void;
  onClear: () => void;
};

function levelColor(level: string) {
  if (level === "error") return "text-red-400";
  if (level === "warn") return "text-yellow-400";
  return "text-gray-300";
}

export function LogPanel({ logs, logText, onCopy, onClear }: LogPanelProps) {
  const logEndRef = useRef<HTMLDivElement | null>(null);
  const reduced = useReducedMotion();

  useEffect(() => {
    logEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [logs]);

  const handleCopy = () => {
    onCopy();
    toast.success("日志已复制");
  };

  return (
    <Card className="h-48 flex flex-col">
      <CardHeader className="flex flex-row items-center justify-between space-y-0 py-2.5 px-4 border-b border-border shrink-0">
        <CardTitle className="flex items-center gap-2 text-base font-medium">
          <Terminal className="h-4 w-4" />
          执行日志
        </CardTitle>
        <div className="flex items-center gap-1">
          <Button variant="ghost" size="sm" onClick={handleCopy} title="复制日志">
            <Copy className="h-3.5 w-3.5" />
          </Button>
          <Button variant="ghost" size="sm" onClick={onClear} title="清空日志">
            <Eraser className="h-3.5 w-3.5" />
          </Button>
        </div>
      </CardHeader>
      <CardContent className="flex-1 p-0 overflow-hidden">
        <ScrollArea className="h-full">
          <div
            className="font-mono leading-relaxed text-xs p-4 min-h-full"
            style={{ background: "hsl(220 15% 8%)" }}
          >
            {logs.length === 0 ? (
              <motion.div
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                transition={{ duration: reduced ? 0 : 0.25 }}
                className="flex flex-col items-center justify-center h-32 gap-2"
              >
                <ScrollText className="h-8 w-8 text-muted-foreground/60" />
                <span className="text-xs text-muted-foreground">暂无日志</span>
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
      </CardContent>
    </Card>
  );
}
