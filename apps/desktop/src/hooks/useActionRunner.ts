import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { ActionFinished, ActionLogDrain, ActionStarted, LogEvent } from "../types";
import { createActionId, waitForPaint } from "../utils/action";
import { levelLabel } from "../utils/status";

export function useActionRunner(refresh: () => Promise<unknown>) {
  const [busy, setBusy] = useState<string | null>(null);
  const [logs, setLogs] = useState<LogEvent[]>([]);
  const [lastError, setLastError] = useState<string | null>(null);
  const activeActionRef = useRef<string | null>(null);
  const finishedActionRef = useRef<string | null>(null);
  const actionLogOffsetRef = useRef(0);
  const pollingActionLogsRef = useRef(false);

  const appendLogs = useCallback((entries: LogEvent[]) => {
    setLogs((items) => [...items, ...entries].slice(-700));
  }, []);

  const appendLog = useCallback(
    (entry: LogEvent) => {
      appendLogs([entry]);
    },
    [appendLogs],
  );

  const runRefresh = useCallback(async () => {
    setBusy((value) => value ?? "detect");
    try {
      await refresh();
      setLastError(null);
    } catch (error) {
      const message = String(error);
      setLastError(message);
      appendLog({ level: "error", message });
    } finally {
      setBusy((value) => (value === "detect" ? null : value));
    }
  }, [appendLog, refresh]);

  const finishBackgroundAction = useCallback(
    async (finished: ActionFinished) => {
      if (finished.actionId !== activeActionRef.current || finishedActionRef.current === finished.actionId) {
        return;
      }

      finishedActionRef.current = finished.actionId;
      activeActionRef.current = null;

      if (finished.ok) {
        appendLog({ level: "info", message: `完成：${finished.action}` });
        setLastError(null);
      } else {
        const message = finished.error ?? `${finished.action} 失败`;
        setLastError(message);
        appendLog({ level: "error", message });
      }

      setBusy(null);
      await runRefresh();

      if (finished.ok) {
        window.alert(`${finished.action} 已完成，可以继续操作。`);
      } else {
        window.alert(`${finished.action} 失败：${finished.error ?? "请查看执行日志。"}`);
      }
    },
    [appendLog, runRefresh],
  );

  useEffect(() => {
    const unlistenLog = listen<LogEvent>("installer-log", (event) => appendLog(event.payload));
    return () => {
      unlistenLog.then((dispose) => dispose()).catch(() => undefined);
    };
  }, [appendLog]);

  useEffect(() => {
    const timer = window.setInterval(() => {
      const actionId = activeActionRef.current;
      if (!actionId || pollingActionLogsRef.current) {
        return;
      }

      pollingActionLogsRef.current = true;
      invoke<ActionLogDrain>("drain_action_logs", {
        actionId,
        offset: actionLogOffsetRef.current,
      })
        .then((drain) => {
          actionLogOffsetRef.current = drain.nextOffset;
          if (drain.logs.length > 0) {
            appendLogs(drain.logs);
          }
          if (drain.finished) {
            void finishBackgroundAction(drain.finished);
          }
        })
        .catch((error) => {
          appendLog({ level: "error", message: `读取后台日志失败: ${String(error)}` });
        })
        .finally(() => {
          pollingActionLogsRef.current = false;
        });
    }, 350);

    return () => window.clearInterval(timer);
  }, [appendLog, appendLogs, finishBackgroundAction]);

  const runAction = useCallback(
    async (name: string, fn: () => Promise<unknown>) => {
      setBusy(name);
      setLastError(null);
      appendLog({ level: "info", message: `开始执行：${name}` });

      try {
        await waitForPaint();
        await fn();
        appendLog({ level: "info", message: `完成：${name}` });
        await runRefresh();
        window.alert(`${name} 已完成，可以继续操作。`);
      } catch (error) {
        const message = String(error);
        setLastError(message);
        appendLog({ level: "error", message });
        window.alert(`${name} 失败：${message}`);
      } finally {
        setBusy(null);
      }
    },
    [appendLog, runRefresh],
  );

  const runBackgroundAction = useCallback(
    async (name: string, fn: (actionId: string) => Promise<ActionStarted>) => {
      const actionId = createActionId(name);
      activeActionRef.current = actionId;
      actionLogOffsetRef.current = 0;
      setBusy(name);
      setLastError(null);
      finishedActionRef.current = null;
      appendLog({ level: "info", message: `开始执行：${name}` });
      appendLog({ level: "info", message: "后台进度会继续显示在这里。" });

      try {
        await waitForPaint();
        const started = await fn(actionId);
        if (finishedActionRef.current !== started.actionId) {
          activeActionRef.current = started.actionId;
          appendLog({ level: "info", message: `后台任务已提交：${name}` });
        }
      } catch (error) {
        const message = String(error);
        activeActionRef.current = null;
        setLastError(message);
        setBusy(null);
        appendLog({ level: "error", message });
        window.alert(`${name} 失败：${message}`);
      }
    },
    [appendLog],
  );

  const logText = useMemo(
    () => logs.map((item) => `[${levelLabel(item.level)}] ${item.message}`).join("\n"),
    [logs],
  );

  return {
    busy,
    logs,
    logText,
    lastError,
    appendLog,
    setLogs,
    runAction,
    runBackgroundAction,
    runRefresh,
  };
}
