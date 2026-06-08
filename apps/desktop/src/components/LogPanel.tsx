import { useEffect, useRef } from "react";
import { Clipboard, Eraser } from "lucide-react";
import type { LogEvent } from "../types";

type LogPanelProps = {
  logs: LogEvent[];
  logText: string;
  onCopy: () => void;
  onClear: () => void;
};

export function LogPanel({ logs, logText, onCopy, onClear }: LogPanelProps) {
  const logRef = useRef<HTMLPreElement | null>(null);

  useEffect(() => {
    const node = logRef.current;
    if (node) {
      node.scrollTop = node.scrollHeight;
    }
  }, [logs]);

  return (
    <section className="logPanel">
      <div className="logHeader">
        <h2>执行日志</h2>
        <div>
          <button className="small" onClick={onCopy} title="复制日志">
            <Clipboard />
            复制
          </button>
          <button className="small" onClick={onClear} title="清空日志">
            <Eraser />
            清空
          </button>
        </div>
      </div>
      <pre ref={logRef}>{logText || "日志会显示在这里。"}</pre>
    </section>
  );
}
