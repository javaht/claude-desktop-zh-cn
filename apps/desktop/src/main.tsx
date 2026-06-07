import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  AlertTriangle,
  CheckCircle2,
  Clipboard,
  Download,
  Eraser,
  Languages,
  Loader2,
  RefreshCw,
  RotateCcw,
  Wrench,
  XCircle,
} from "lucide-react";
import "./styles.css";

type EnvironmentReport = {
  platform: string;
  arch: string;
  resourcesDir?: string | null;
  resourcesOk: boolean;
  resourceIssues: string[];
  claudePath?: string | null;
  resourcesPath?: string | null;
  installKind?: string | null;
  isAdmin: boolean;
  needsAdmin: boolean;
  currentLocale?: string | null;
  backupCount: number;
  ccSwitchSkillsDir?: string | null;
  skillsPluginRoot?: string | null;
  autoUpdatesEnabled?: boolean | null;
  warnings: string[];
};

type LogEvent = {
  level: "info" | "warn" | "error" | string;
  message: string;
};

type ActionStarted = {
  actionId: string;
};

type ActionFinished = {
  actionId: string;
  action: string;
  ok: boolean;
  error?: string | null;
};

type ActionLogDrain = {
  logs: LogEvent[];
  nextOffset: number;
  finished?: ActionFinished | null;
};

type ResourceReleaseManifest = {
  repo: string;
  release: string;
};

type GitHubRelease = {
  tag_name: string;
  html_url: string;
  zipball_url: string;
};

type Language = "zh-CN" | "zh-TW" | "zh-HK";
type PatchMode = "safe" | "official";

const languages: Array<{ value: Language; label: string; hint: string }> = [
  { value: "zh-CN", label: "简体中文", hint: "中国大陆" },
  { value: "zh-TW", label: "繁体中文", hint: "中国台湾" },
  { value: "zh-HK", label: "繁体中文", hint: "中国香港" },
];

const modes: Array<{ value: PatchMode; label: string; hint: string; risk: string }> = [
  {
    value: "safe",
    label: "第三方 API",
    hint: "轻量资源汉化，保持 Cowork / 沙箱兼容",
    risk: "适合第三方 API、截图工作区或沙箱用户。",
  },
  {
    value: "official",
    label: "官方账号登录",
    hint: "启用在线页面显示层汉化",
    risk: "会修改 app.asar，Windows 签名状态会改变。",
  },
];

function statusText(env: EnvironmentReport | null) {
  if (!env) return "等待检测";
  if (!env.resourcesOk) return "资源异常";
  if (!env.claudePath) return "未找到 Claude";
  return "可执行";
}

function levelLabel(level: string) {
  if (level === "error") return "错误";
  if (level === "warn") return "警告";
  return "日志";
}

function waitForPaint() {
  return new Promise<void>((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
  });
}

function createActionId(name: string) {
  return `${name}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function normalizeVersion(version: string) {
  return version.trim().replace(/^v/i, "");
}

function compareVersions(left: string, right: string) {
  const a = normalizeVersion(left).split(/[.-]/).map((part) => Number.parseInt(part, 10) || 0);
  const b = normalizeVersion(right).split(/[.-]/).map((part) => Number.parseInt(part, 10) || 0);
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    const diff = (a[index] ?? 0) - (b[index] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

function App() {
  const [env, setEnv] = useState<EnvironmentReport | null>(null);
  const [language, setLanguage] = useState<Language>("zh-CN");
  const [mode, setMode] = useState<PatchMode>("safe");
  const [launchAfter, setLaunchAfter] = useState(true);
  const [dryRun, setDryRun] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [logs, setLogs] = useState<LogEvent[]>([]);
  const [lastError, setLastError] = useState<string | null>(null);
  const logRef = useRef<HTMLPreElement | null>(null);
  const activeActionRef = useRef<string | null>(null);
  const finishedActionRef = useRef<string | null>(null);
  const actionLogOffsetRef = useRef(0);
  const pollingActionLogsRef = useRef(false);
  const checkedResourceUpdateRef = useRef(false);

  const appendLogs = useCallback((entries: LogEvent[]) => {
    setLogs((items) => [...items, ...entries].slice(-700));
  }, []);

  const appendLog = useCallback((entry: LogEvent) => {
    appendLogs([entry]);
  }, [appendLogs]);

  const refresh = useCallback(async () => {
    setBusy((value) => value ?? "detect");
    try {
      const report = await invoke<EnvironmentReport>("detect_environment");
      setEnv(report);
      setLastError(null);
    } catch (error) {
      const message = String(error);
      setLastError(message);
      appendLog({ level: "error", message });
    } finally {
      setBusy((value) => (value === "detect" ? null : value));
    }
  }, [appendLog]);

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
      await refresh();
      if (finished.ok) {
        window.alert(`${finished.action} 已完成，可以继续操作。`);
      } else {
        window.alert(`${finished.action} 失败：${finished.error ?? "请查看执行日志。"}`);
      }
    },
    [appendLog, refresh],
  );

  useEffect(() => {
    const unlistenLog = listen<LogEvent>("installer-log", (event) => appendLog(event.payload));
    refresh();
    return () => {
      unlistenLog.then((dispose) => dispose()).catch(() => undefined);
    };
  }, [appendLog, refresh]);

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

  useEffect(() => {
    const node = logRef.current;
    if (node) {
      node.scrollTop = node.scrollHeight;
    }
  }, [logs]);

  const canRun = Boolean(env?.resourcesOk && env?.claudePath && !busy);
  const selectedLanguage = useMemo(() => languages.find((item) => item.value === language), [language]);
  const selectedMode = useMemo(() => modes.find((item) => item.value === mode), [mode]);
  const logText = logs.map((item) => `[${levelLabel(item.level)}] ${item.message}`).join("\n");

  const runAction = useCallback(
    async (name: string, fn: () => Promise<void>) => {
      setBusy(name);
      setLastError(null);
      appendLog({ level: "info", message: `开始执行：${name}` });
      try {
        await waitForPaint();
        await fn();
        appendLog({ level: "info", message: `完成：${name}` });
        await refresh();
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
    [appendLog, refresh],
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

  const checkResourceUpdate = useCallback(async () => {
    if (checkedResourceUpdateRef.current) {
      return;
    }
    checkedResourceUpdateRef.current = true;
    try {
      const manifest = await invoke<ResourceReleaseManifest>("resource_release_manifest");
      const response = await fetch(`https://api.github.com/repos/${manifest.repo}/releases/latest`, {
        headers: { Accept: "application/vnd.github+json" },
      });
      if (!response.ok) {
        throw new Error(`GitHub release 检查失败: ${response.status}`);
      }
      const latest = (await response.json()) as GitHubRelease;
      const latestVersion = normalizeVersion(latest.tag_name);
      const currentVersion = normalizeVersion(manifest.release);
      if (!latest.zipball_url || compareVersions(latestVersion, currentVersion) <= 0) {
        return;
      }
      const shouldUpdate = window.confirm(
        `发现补丁资源更新：${currentVersion} -> ${latestVersion}\n\n是否现在下载并更新？`,
      );
      if (!shouldUpdate) {
        return;
      }
      await runBackgroundAction("更新补丁资源", (actionId) =>
        invoke<ActionStarted>("install_resource_update", {
          actionId,
          zipballUrl: latest.zipball_url,
          release: latestVersion,
          repo: manifest.repo,
        }),
      );
    } catch (error) {
      appendLog({ level: "warn", message: `检查补丁资源更新失败: ${String(error)}` });
    }
  }, [appendLog, runBackgroundAction]);

  useEffect(() => {
    void checkResourceUpdate();
  }, [checkResourceUpdate]);

  return (
    <main className="shell">
      <header className="topbar">
        <div>
          <div className="eyebrow">Claude Desktop 中文补丁 RS</div>
          <h1>双端 Rust 安装器</h1>
        </div>
        <button className="iconButton" onClick={refresh} disabled={Boolean(busy)} title="重新检测">
          {busy === "detect" ? <Loader2 className="spin" /> : <RefreshCw />}
        </button>
      </header>

      <section className="statusBand">
        <div className="statusItem">
          <span className="statusIcon ok">{env?.claudePath ? <CheckCircle2 /> : <XCircle />}</span>
          <div>
            <strong>{statusText(env)}</strong>
            <span>{env ? `${env.platform} / ${env.arch}` : "尚未完成环境检测"}</span>
          </div>
        </div>
        <div className="statusItem">
          <span className="statusIcon"><Wrench /></span>
          <div>
            <strong>{env?.installKind ?? "未知安装类型"}</strong>
            <span>{env?.claudePath ?? "未检测到安装路径"}</span>
          </div>
        </div>
        <div className="statusItem">
          <span className="statusIcon"><Languages /></span>
          <div>
            <strong>{env?.currentLocale ?? "未设置语言"}</strong>
            <span>{env?.backupCount ?? 0} 个补丁备份</span>
          </div>
        </div>
      </section>

      {(lastError || env?.warnings?.length || env?.resourceIssues?.length) ? (
        <section className="notice">
          <AlertTriangle />
          <div>
            {lastError ? <strong>{lastError}</strong> : <strong>检测到需要注意的事项</strong>}
            {[...(env?.warnings ?? []), ...(env?.resourceIssues ?? [])].slice(0, 5).map((item) => (
              <span key={item}>{item}</span>
            ))}
          </div>
        </section>
      ) : null}

      <div className="grid">
        <section className="panel">
          <div className="panelHeader">
            <h2>安装补丁</h2>
            <span>语言、模式、启动选项</span>
          </div>

          <div className="controlGrid">
            <label className="selectField">
              <span>语言</span>
              <select value={language} onChange={(event) => setLanguage(event.target.value as Language)} disabled={Boolean(busy)}>
                {languages.map((item) => (
                  <option key={item.value} value={item.value}>
                    {item.label} · {item.hint}
                  </option>
                ))}
              </select>
            </label>

            <label className="selectField">
              <span>安装模式</span>
              <select value={mode} onChange={(event) => setMode(event.target.value as PatchMode)} disabled={Boolean(busy)}>
                {modes.map((item) => (
                  <option key={item.value} value={item.value}>
                    {item.label}
                  </option>
                ))}
              </select>
            </label>
          </div>

          <div className="selectHint">
            <span>{selectedLanguage?.hint}</span>
            <span>{selectedMode?.hint}</span>
            <span>{selectedMode?.risk}</span>
          </div>

          <div className="toggles">
            <label>
              <input type="checkbox" checked={launchAfter} onChange={(e) => setLaunchAfter(e.target.checked)} />
              完成后启动 Claude
            </label>
            <label>
              <input type="checkbox" checked={dryRun} onChange={(e) => setDryRun(e.target.checked)} />
              dry-run 验证
            </label>
          </div>

          <button
            className="primary"
            disabled={!canRun}
            onClick={() =>
              runBackgroundAction("安装中文补丁", (actionId) =>
                invoke<ActionStarted>("install_patch", {
                  actionId,
                  request: { language, mode, launchAfter, dryRun },
                }),
              )
            }
          >
            {busy === "安装中文补丁" ? <Loader2 className="spin" /> : <Download />}
            {busy === "安装中文补丁" ? "正在安装..." : "安装中文补丁"}
          </button>
          {busy === "安装中文补丁" ? (
            <div className="progressLine" aria-live="polite">
              <Loader2 className="spin" />
              <span>授权已提交，正在复制、补丁和签名 Claude.app。</span>
            </div>
          ) : null}
        </section>

        <section className="panel">
          <div className="panelHeader">
            <h2>维护操作</h2>
            <span>恢复、更新、skills 同步</span>
          </div>

          <div className="actions">
            <button
              disabled={!canRun}
              onClick={() =>
                runBackgroundAction("恢复原样", (actionId) => invoke<ActionStarted>("restore_patch", { actionId }))
              }
            >
              <RotateCcw />
              恢复 / 卸载补丁
            </button>
            <button disabled={Boolean(busy)} onClick={() => runAction("开启自动更新", () => invoke("set_auto_updates", { enabled: true }))}>
              <CheckCircle2 />
              允许自动更新
            </button>
            <button disabled={Boolean(busy)} onClick={() => runAction("停止自动更新", () => invoke("set_auto_updates", { enabled: false }))}>
              <XCircle />
              停止自动更新
            </button>
            <button disabled={Boolean(busy)} onClick={() => runAction("同步 CC Switch skills", () => invoke("sync_cc_switch_skills"))}>
              <Wrench />
              同步 CC Switch skills
            </button>
            <button disabled={Boolean(busy)} onClick={() => runAction("删除 skills 同步", () => invoke("unsync_cc_switch_skills"))}>
              <Eraser />
              删除 skills 同步
            </button>
          </div>

          <dl className="facts">
            <div>
              <dt>资源目录</dt>
              <dd>{env?.resourcesDir ?? "-"}</dd>
            </div>
            <div>
              <dt>Claude resources</dt>
              <dd>{env?.resourcesPath ?? "-"}</dd>
            </div>
            <div>
              <dt>skills 来源</dt>
              <dd>{env?.ccSwitchSkillsDir ?? "-"}</dd>
            </div>
            <div>
              <dt>skills plugin</dt>
              <dd>{env?.skillsPluginRoot ?? "-"}</dd>
            </div>
          </dl>
        </section>
      </div>

      <section className="logPanel">
        <div className="logHeader">
          <h2>执行日志</h2>
          <div>
            <button className="small" onClick={() => navigator.clipboard.writeText(logText)} title="复制日志">
              <Clipboard />
              复制
            </button>
            <button className="small" onClick={() => setLogs([])} title="清空日志">
              <Eraser />
              清空
            </button>
          </div>
        </div>
        <pre ref={logRef}>{logText || "日志会显示在这里。"}</pre>
      </section>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
