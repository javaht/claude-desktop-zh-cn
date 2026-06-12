import { AlertTriangle, CheckCircle2, FlaskConical, Loader2, Lock, Rocket, Zap } from "lucide-react";
import { cn } from "@/lib/utils";
import { useLayoutEffect, useState } from "react";
import type { EnvironmentReport } from "../types";

type StatusSummaryProps = {
  env: EnvironmentReport | null;
  busy: string | null;
  lastError: string | null;
  launchAfter: boolean;
  onLaunchAfterChange: (checked: boolean) => void;
  dryRun: boolean;
  onDryRunChange: (checked: boolean) => void;
  onAutoUpdateChange: (checked: boolean) => void;
};

export function StatusSummary({
  env,
  busy,
  lastError,
  launchAfter,
  onLaunchAfterChange,
  dryRun,
  onDryRunChange,
  onAutoUpdateChange,
}: StatusSummaryProps) {
  const autoUpdates = env?.autoUpdatesEnabled ?? true;
  const isWindows = env?.platform === "Windows";
  const disabled = busy !== null;

  // 三个互斥状态
  const isLoading = env === null;
  const isError =
    env !== null &&
    (!env.claudePath || !env.resourcesOk || (env.resourceIssues?.length ?? 0) > 0);
  const isReady =
    env !== null &&
    Boolean(env.claudePath) &&
    env.resourcesOk &&
    (env.resourceIssues?.length ?? 0) === 0;

  // B 态时序控制
  const [showSuccess, setShowSuccess] = useState(false);
  const [showCards, setShowCards] = useState(false);
  const pathStr = env?.claudePath ?? null;

  useLayoutEffect(() => {
    if (!pathStr) {
      setShowSuccess(false);
      setShowCards(false);
      return;
    }

    setShowSuccess(true);
    setShowCards(false);

    const timer = window.setTimeout(() => {
      setShowSuccess(false);
      setShowCards(true);
    }, 1800);

    return () => window.clearTimeout(timer);
  }, [pathStr]);

  const segmentedBase =
    "flex items-center justify-center gap-1 rounded-md p-1.5 transition-all duration-150 select-none";
  const segmentedOn =
    "bg-primary/10 text-foreground shadow-[inset_0_0_0_1px_hsl(var(--primary)/0.25)]";
  const segmentedOff =
    "text-muted-foreground/70 hover:text-muted-foreground hover:bg-muted/40";
  const iconOn = "text-primary";
  const iconOff = "text-muted-foreground/40";

  const glowGreen =
    "shadow-[0_0_0_1px_hsl(var(--success)/0.4),0_0_12px_-2px_hsl(var(--success)/0.5)]";
  const glowRed =
    "shadow-[0_0_0_1px_hsl(var(--error)/0.4),0_0_12px_-2px_hsl(var(--error)/0.5)]";

  return (
    <div className="space-y-2">
      <div
        className={cn(
          "relative rounded-lg border bg-card p-1.5 shadow-sm overflow-visible transition-all duration-300",
          isLoading && "border-border-subtle",
          isError && [
            "border-[hsl(var(--error)/0.45)] dark:border-[hsl(var(--error)/0.6)]",
            glowRed,
          ],
          isReady && showCards && [
            "border-[hsl(var(--success)/0.45)] dark:border-[hsl(var(--success)/0.6)]",
            glowGreen,
          ],
          isReady && !showCards && [
            "border-[hsl(var(--success)/0.35)] dark:border-[hsl(var(--success)/0.5)]",
          ]
        )}
      >
        {/* 高度占位骨架 - 永远不可见，永久锁定容器高度 = 3 卡 + padding */}
        <div
          className="grid grid-cols-3 gap-1 opacity-0 pointer-events-none select-none"
          aria-hidden="true"
        >
          <div className={segmentedBase}>
            <Zap className="h-3 w-3" />
            <span className="text-[10.5px] font-medium truncate">自动更新</span>
            {isWindows && <Lock className="h-2 w-2" aria-hidden="true" />}
          </div>
          <div className={segmentedBase}>
            <Rocket className="h-3 w-3" />
            <span className="text-[10.5px] font-medium truncate">启动应用</span>
          </div>
          <div className={segmentedBase}>
            <FlaskConical className="h-3 w-3" />
            <span className="text-[10.5px] font-medium truncate">试运行</span>
          </div>
        </div>

        {/* B 稳定态：3 张 toggle 卡 - absolute 覆盖在骨架位置 */}
        <div
          className={cn(
            "absolute inset-x-1.5 top-1.5 grid grid-cols-3 gap-1 transition-all duration-500 ease-out",
            isReady && showCards
              ? "opacity-100 translate-y-0 pointer-events-auto"
              : "opacity-0 translate-y-0.5 pointer-events-none"
          )}
        >
          <button
            type="button"
            onClick={() => onAutoUpdateChange(!autoUpdates)}
            disabled={disabled}
            className={cn(segmentedBase, autoUpdates ? segmentedOn : segmentedOff)}
            aria-pressed={autoUpdates}
            title={isWindows ? "切换时会弹出 Windows 授权弹窗" : undefined}
          >
            <Zap className={cn("h-3 w-3 flex-shrink-0", autoUpdates ? iconOn : iconOff)} />
            <span className="text-[10.5px] font-medium truncate">自动更新</span>
            {isWindows && (
              <Lock
                className={cn(
                  "h-2 w-2 flex-shrink-0",
                  autoUpdates ? "text-primary/60" : "text-muted-foreground/50"
                )}
                aria-hidden="true"
              />
            )}
          </button>

          <button
            type="button"
            onClick={() => onLaunchAfterChange(!launchAfter)}
            disabled={disabled}
            className={cn(segmentedBase, launchAfter ? segmentedOn : segmentedOff)}
            aria-pressed={launchAfter}
          >
            <Rocket className={cn("h-3 w-3 flex-shrink-0", launchAfter ? iconOn : iconOff)} />
            <span className="text-[10.5px] font-medium truncate">启动应用</span>
          </button>

          <button
            type="button"
            onClick={() => onDryRunChange(!dryRun)}
            disabled={disabled}
            className={cn(segmentedBase, dryRun ? segmentedOn : segmentedOff)}
            aria-pressed={dryRun}
          >
            <FlaskConical className={cn("h-3 w-3 flex-shrink-0", dryRun ? iconOn : iconOff)} />
            <span className="text-[10.5px] font-medium truncate">试运行</span>
          </button>
        </div>

        {/* A 态：检测中... - absolute inset-0 居中覆盖 3 卡槽位 */}
        <div
          className={cn(
            "absolute inset-0 flex items-center justify-center gap-1.5 transition-opacity duration-300",
            isLoading ? "opacity-100" : "opacity-0 pointer-events-none"
          )}
        >
          <Loader2 className="h-3 w-3 animate-spin text-muted-foreground" />
          <span className="text-[10.5px] text-muted-foreground">检测中…</span>
        </div>

        {/* B 弹出：绿色"可执行" - absolute inset-0 居中，1.8s 后淡出 */}
        <div
          className={cn(
            "absolute inset-0 flex items-center justify-center gap-1 transition-all duration-500 ease-out",
            isReady && showSuccess
              ? "opacity-100 scale-100"
              : "opacity-0 scale-95 pointer-events-none"
          )}
        >
          <CheckCircle2 className="h-3 w-3 flex-shrink-0 text-[hsl(var(--success))]" />
          <span className="text-[10.5px] font-medium text-[hsl(var(--success))]">可执行</span>
        </div>

        {/* C 态：单行错误提示 - absolute inset-0 居中覆盖 3 卡槽位 */}
        <div
          className={cn(
            "absolute inset-0 flex items-center justify-center gap-1 px-2 transition-all duration-300 ease-out",
            isError
              ? "opacity-100 translate-y-0"
              : "opacity-0 -translate-y-1 pointer-events-none"
          )}
        >
          <AlertTriangle className="h-3 w-3 flex-shrink-0 text-[hsl(var(--error))] opacity-90" />
          <span
            className="text-[11px] font-medium text-[hsl(var(--error))] truncate"
            title={
              lastError ||
              env?.resourceIssues?.[0] ||
              env?.warnings?.[0] ||
              "环境检查未通过"
            }
          >
            {lastError ||
              env?.resourceIssues?.[0] ||
              env?.warnings?.[0] ||
              "环境检查未通过"}
          </span>
        </div>
      </div>
    </div>
  );
}
