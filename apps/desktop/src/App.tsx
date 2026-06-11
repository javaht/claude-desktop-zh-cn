import { useCallback, useEffect, useState } from "react";
import { motion } from "framer-motion";
import { invoke } from "@tauri-apps/api/core";
import { ActionButtons } from "./components/ActionButtons";
import { InstallOptions } from "./components/InstallOptions";
import { LogPanel } from "./components/LogPanel";
import { StatusPanel } from "./components/StatusPanel";
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
import { Toaster } from "@/components/ui/sonner";
import { fadeInUp, staggerContainer, useReducedMotion } from "./lib/motion";
import { useActionRunner } from "./hooks/useActionRunner";
import { useEnvironment } from "./hooks/useEnvironment";
import { useResourceRelease } from "./hooks/useResourceRelease";
import { useTheme } from "./hooks/useTheme";
import type { ActionStarted, Language, PatchMode } from "./types";

export default function App() {
  const { theme } = useTheme(); // 跟随系统主题
  const reduced = useReducedMotion();
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

  const handleRefresh = useCallback(() => {
    void runRefresh();
  }, [runRefresh]);

  const handleInstall = useCallback(() => {
    void runBackgroundAction("安装中文补丁", (actionId) =>
      invoke<ActionStarted>("install_patch", {
        actionId,
        request: { language, mode, launchAfter, dryRun },
      }),
    );
  }, [dryRun, language, launchAfter, mode, runBackgroundAction]);

  const handleRestore = useCallback(() => {
    void runBackgroundAction("恢复原样", (actionId) => invoke<ActionStarted>("restore_patch", { actionId }));
  }, [runBackgroundAction]);

  const handleEnableAutoUpdates = useCallback(() => {
    void runAction("开启自动更新", () => invoke("set_auto_updates", { enabled: true }));
  }, [runAction]);

  const handleDisableAutoUpdates = useCallback(() => {
    void runAction("停止自动更新", () => invoke("set_auto_updates", { enabled: false }));
  }, [runAction]);

  const handleSyncSkills = useCallback(() => {
    void runAction("同步 CC Switch skills", () => invoke("sync_cc_switch_skills"));
  }, [runAction]);

  const handleUnsyncSkills = useCallback(() => {
    void runAction("删除 skills 同步", () => invoke("unsync_cc_switch_skills"));
  }, [runAction]);

  const handleCopyLogs = useCallback(() => {
    void navigator.clipboard.writeText(logText);
  }, [logText]);

  const handleClearLogs = useCallback(() => {
    setLogs([]);
  }, [setLogs]);

  return (
    <div className="flex flex-col h-screen bg-background text-foreground">
      <TitleBar />
      <motion.main
        className="flex-1 overflow-y-auto flex flex-col p-4 gap-4"
        variants={staggerContainer}
        initial="hidden"
        animate="visible"
      >
        <motion.div variants={fadeInUp} transition={{ duration: reduced ? 0 : 0.2, ease: "easeOut" }}>
          <StatusPanel env={env} busy={busy} lastError={lastError} onRefresh={handleRefresh} />
        </motion.div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4 flex-1 min-h-0">
          <motion.div variants={fadeInUp} transition={{ duration: reduced ? 0 : 0.2, ease: "easeOut" }}>
            <InstallOptions
              language={language}
              mode={mode}
              launchAfter={launchAfter}
              dryRun={dryRun}
              busy={busy}
              canRun={canRun}
              onLanguageChange={setLanguage}
              onModeChange={setMode}
              onLaunchAfterChange={setLaunchAfter}
              onDryRunChange={setDryRun}
              onInstall={handleInstall}
            />
          </motion.div>
          <motion.div variants={fadeInUp} transition={{ duration: reduced ? 0 : 0.2, ease: "easeOut" }}>
            <ActionButtons
              canRun={canRun}
              busy={busy}
              onRestore={handleRestore}
              onEnableAutoUpdates={handleEnableAutoUpdates}
              onDisableAutoUpdates={handleDisableAutoUpdates}
              onSyncSkills={handleSyncSkills}
              onUnsyncSkills={handleUnsyncSkills}
            />
          </motion.div>
        </div>

        <motion.div variants={fadeInUp} transition={{ duration: reduced ? 0 : 0.2, ease: "easeOut" }}>
          <LogPanel logs={logs} logText={logText} onCopy={handleCopyLogs} onClear={handleClearLogs} />
        </motion.div>
      </motion.main>

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
  );
}
