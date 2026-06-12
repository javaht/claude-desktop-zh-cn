import { useCallback, useEffect, useState } from "react";
import { Download, LifeBuoy, Loader2, Star } from "lucide-react";
import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import { LogPanel } from "./components/LogPanel";
import { StatusSummary } from "./components/StatusSummary";
import { TitleBar } from "./components/TitleBar";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useActionRunner } from "./hooks/useActionRunner";
import { useEnvironment } from "./hooks/useEnvironment";
import { useResourceRelease } from "./hooks/useResourceRelease";
import { useTheme } from "./hooks/useTheme";
import { languages, modes } from "./constants";
import type { ActionStarted, Language, PatchMode } from "./types";

export default function App() {
  const { theme } = useTheme();
  const { env, detectEnvironment } = useEnvironment();
  const {
    busy,
    logs,
    logText,
    lastError,
    appendLog,
    setLogs,
    runAction,
    runBackgroundAction,
    runRefresh,
  } = useActionRunner(detectEnvironment);
  const [language, setLanguage] = useState<Language>("zh-CN");
  const [mode, setMode] = useState<PatchMode>("safe");
  const [launchAfter, setLaunchAfter] = useState(true);
  const [dryRun, setDryRun] = useState(false);
  useEffect(() => {
    void runRefresh();
  }, [runRefresh]);

  const { pendingUpdate, approveUpdate, dismissUpdate } = useResourceRelease(appendLog, runBackgroundAction, Boolean(busy));

  const canRun = Boolean(env?.resourcesOk && env?.claudePath && !busy);

  const handleInstall = useCallback(() => {
    void runBackgroundAction("安装中文补丁", (actionId) =>
      invoke<ActionStarted>("install_patch", {
        actionId,
        request: { language, mode, launchAfter, dryRun },
      }),
    );
  }, [dryRun, language, launchAfter, mode, runBackgroundAction]);

  const handleRestore = useCallback(() => {
    void runBackgroundAction("恢复原样", (actionId) =>
      invoke<ActionStarted>("restore_patch", { actionId, request: { dryRun } }),
    );
  }, [dryRun, runBackgroundAction]);

  const handleEnableAutoUpdates = useCallback(() => {
    void runAction("开启自动更新", () => invoke("set_auto_updates", { enabled: true }));
  }, [runAction]);

  const handleDisableAutoUpdates = useCallback(() => {
    void runAction("停止自动更新", () => invoke("set_auto_updates", { enabled: false }));
  }, [runAction]);

  const handleCopyLogs = useCallback(async () => {
    await navigator.clipboard.writeText(logText);
  }, [logText]);

  const handleAutoUpdateChange = useCallback(
    (checked: boolean) => {
      if (checked) {
        handleEnableAutoUpdates();
      } else {
        handleDisableAutoUpdates();
      }
    },
    [handleEnableAutoUpdates, handleDisableAutoUpdates],
  );

  return (
    <TooltipProvider>
      <div className="flex flex-col h-screen bg-background text-foreground">
        <TitleBar />

        <main className="flex-1 overflow-hidden px-3 py-1">
          <div className="w-full flex flex-col gap-2">
            {/* Quick links: 冷暖分割号召条 */}
            <div className="flex rounded-xl overflow-hidden h-8 select-none bg-neutral-100/60 dark:bg-neutral-800/30 ring-1 ring-border/30 dark:ring-border/20">
              <button
                type="button"
                onClick={() => void openUrl("https://github.com/anthropics/claude-code/issues")}
                className="flex-1 flex items-center justify-center gap-1.5 text-neutral-600 dark:text-neutral-300 hover:text-sky-700 dark:hover:text-sky-300 hover:bg-sky-500/[0.06] dark:hover:bg-sky-400/[0.08] transition-all duration-200 cursor-pointer active:scale-[0.98] group"
                title="去 GitHub Issues 反馈问题"
                aria-label="遇到问题"
              >
                <LifeBuoy className="h-4 w-4 flex-shrink-0 text-slate-500 group-hover:text-sky-600 dark:text-neutral-400 dark:group-hover:text-sky-400 transition-colors duration-200" />
                <span className="text-[11px] font-medium">遇到问题 ？</span>
              </button>
              <div className="w-px bg-border/30 self-stretch" />
              <button
                type="button"
                onClick={() => void openUrl("https://github.com/anthropics/claude-code")}
                className="flex-1 flex items-center justify-center gap-1.5 text-neutral-600 dark:text-neutral-300 hover:text-amber-800 dark:hover:text-amber-200 hover:bg-amber-500/[0.06] dark:hover:bg-amber-400/[0.08] transition-all duration-200 cursor-pointer active:scale-[0.98] group"
                title="给 Claude Code 点个 Star"
                aria-label="点个 Star"
              >
                <Star className="h-4 w-4 flex-shrink-0 text-neutral-500 group-hover:text-amber-600 dark:text-neutral-400 dark:group-hover:text-amber-400 group-hover:rotate-12 transition-all duration-200" />
                <span className="text-[11px] font-medium">点个 Star ！</span>
              </button>
            </div>
            {/* Status + options grid (3 toggle cards + container border state) */}
            <StatusSummary
              env={env}
              busy={busy}
              lastError={lastError}
              launchAfter={launchAfter}
              onLaunchAfterChange={setLaunchAfter}
              dryRun={dryRun}
              onDryRunChange={setDryRun}
              onAutoUpdateChange={handleAutoUpdateChange}
            />

            {/* Core action: language + mode + install + uninstall */}
            <div className="grid grid-cols-2 gap-2">
              <div className="flex items-center gap-1">
                <Label className="text-[10px] text-muted-foreground uppercase tracking-wide shrink-0 leading-none">语言</Label>
                <div className="flex-1 min-w-0">
                  <Select value={language} onValueChange={(v) => setLanguage(v as Language)} disabled={Boolean(busy)}>
                    <SelectTrigger className="h-7 text-[12px] px-2.5 w-full">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent position="popper">
                      {languages.map((item) => (
                        <SelectItem key={item.value} value={item.value} className="text-[13px]">
                          {item.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </div>
              <div className="flex items-center gap-1">
                <Label className="text-[10px] text-muted-foreground uppercase tracking-wide shrink-0 leading-none">模式</Label>
                <div className="flex-1 min-w-0">
                  <Select value={mode} onValueChange={(v) => setMode(v as PatchMode)} disabled={Boolean(busy)}>
                    <SelectTrigger className="h-7 text-[12px] px-2.5 w-full">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent position="popper">
                      {modes.map((item) => (
                        <SelectItem key={item.value} value={item.value} className="text-[13px]">
                          {item.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </div>
            </div>

            <div className="flex flex-col gap-1">
              <div className="grid grid-cols-[65fr_35fr] gap-1.5">
                <Button
                  className="w-full min-w-0 h-9 rounded-lg text-[12px] font-medium transition-all duration-150 hover:bg-primary/90 active:scale-[0.98] active:bg-primary/95 focus-visible:ring-1 focus-visible:ring-ring focus-visible:ring-offset-1 px-3 disabled:opacity-50"
                  disabled={!canRun}
                  onClick={handleInstall}
                >
                  {busy === "安装中文补丁" ? (
                    <Loader2 className="h-3 w-3 animate-spin" />
                  ) : (
                    <Download className="h-3 w-3" />
                  )}
                  <span className="truncate">{busy === "安装中文补丁" ? "安装中…" : "安装补丁"}</span>
                </Button>
                <Button
                  className="w-full min-w-0 h-9 rounded-lg text-[12px] font-medium px-3 text-muted-foreground hover:text-foreground hover:bg-muted active:scale-[0.98] transition-all focus-visible:ring-1 focus-visible:ring-ring focus-visible:ring-offset-1"
                  variant="secondary"
                  disabled={busy !== null}
                  onClick={handleRestore}
                >
                  卸载补丁
                </Button>
              </div>

            </div>

            {/* LogPanel */}
            <LogPanel
              logs={logs}
              logText={logText}
              onCopy={handleCopyLogs}
            />
          </div>
        </main>

        <AlertDialog open={!!pendingUpdate} onOpenChange={(open) => { if (!open) dismissUpdate(); }}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>发现补丁资源更新</AlertDialogTitle>
              <AlertDialogDescription>
                检测到新版本 {pendingUpdate?.release}，是否现在下载并更新？
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel onClick={dismissUpdate}>稍后再说</AlertDialogCancel>
              <AlertDialogAction onClick={() => void approveUpdate()}>立即更新</AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>

        <Toaster richColors position="bottom-right" closeButton theme={theme} />
      </div>
    </TooltipProvider>
  );
}
