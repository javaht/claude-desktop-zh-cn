import { AlertTriangle, CheckCircle2, Languages, Loader2, RefreshCw, Wrench, XCircle } from "lucide-react";
import type { EnvironmentReport } from "../types";
import { compactPath, statusText } from "../utils/status";

type StatusPanelProps = {
  env: EnvironmentReport | null;
  busy: string | null;
  lastError: string | null;
  onRefresh: () => void;
};

export function StatusPanel({ env, busy, lastError, onRefresh }: StatusPanelProps) {
  return (
    <>
      <header className="topbar">
        <div>
          <div className="eyebrow">Claude-Zh</div>
          <h1>双端 Rust 安装器</h1>
        </div>
        <button className="iconButton" onClick={onRefresh} disabled={Boolean(busy)} title="重新检测">
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
            <span title={env?.claudePath ?? undefined}>{env?.claudePath ? compactPath(env.claudePath) : "未检测到安装路径"}</span>
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
    </>
  );
}
