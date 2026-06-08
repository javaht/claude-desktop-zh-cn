import { Download, Loader2 } from "lucide-react";
import { languages, modes } from "../constants";
import type { Language, PatchMode } from "../types";

type InstallOptionsProps = {
  language: Language;
  mode: PatchMode;
  launchAfter: boolean;
  dryRun: boolean;
  busy: string | null;
  canRun: boolean;
  onLanguageChange: (language: Language) => void;
  onModeChange: (mode: PatchMode) => void;
  onLaunchAfterChange: (checked: boolean) => void;
  onDryRunChange: (checked: boolean) => void;
  onInstall: () => void;
};

export function InstallOptions({
  language,
  mode,
  launchAfter,
  dryRun,
  busy,
  canRun,
  onLanguageChange,
  onModeChange,
  onLaunchAfterChange,
  onDryRunChange,
  onInstall,
}: InstallOptionsProps) {
  return (
    <section className="panel">
      <div className="panelHeader">
        <h2>安装补丁</h2>
      </div>

      <div className="controlGrid">
        <label className="selectField">
          <span>语言</span>
          <select value={language} onChange={(event) => onLanguageChange(event.target.value as Language)} disabled={Boolean(busy)}>
            {languages.map((item) => (
              <option key={item.value} value={item.value}>
                {item.label}
              </option>
            ))}
          </select>
        </label>

        <label className="selectField">
          <span>安装模式</span>
          <select value={mode} onChange={(event) => onModeChange(event.target.value as PatchMode)} disabled={Boolean(busy)}>
            {modes.map((item) => (
              <option key={item.value} value={item.value}>
                {item.label}
              </option>
            ))}
          </select>
        </label>
      </div>

      <div className="toggles">
        <label>
          <input type="checkbox" checked={launchAfter} onChange={(event) => onLaunchAfterChange(event.target.checked)} />
          完成后启动 Claude
        </label>
        <label>
          <input type="checkbox" checked={dryRun} onChange={(event) => onDryRunChange(event.target.checked)} />
          dry-run 验证
        </label>
      </div>

      <button className="primary" disabled={!canRun} onClick={onInstall}>
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
  );
}
