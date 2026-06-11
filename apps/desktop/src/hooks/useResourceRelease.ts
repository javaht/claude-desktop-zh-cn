import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { toast } from "sonner";
import type { ActionStarted, GitHubRelease, LogEvent, ResourceReleaseManifest } from "../types";
import { compareVersions, normalizeVersion } from "../utils/version";

type PendingUpdate = {
  release: string;
  zipballUrl: string;
  repo: string;
};

export function useResourceRelease(
  appendLog: (entry: LogEvent) => void,
  runBackgroundAction: (
    name: string,
    fn: (actionId: string) => Promise<ActionStarted>,
  ) => Promise<void>,
  busy: boolean,
) {
  const checkedResourceUpdateRef = useRef(false);
  const [pendingUpdate, setPendingUpdate] = useState<PendingUpdate | null>(null);
  const runBackgroundActionRef = useRef(runBackgroundAction);
  runBackgroundActionRef.current = runBackgroundAction;

  const approveUpdate = useCallback(async () => {
    if (busy) {
      toast.warning("当前有任务在执行，请稍候再确认");
      return;
    }
    if (!pendingUpdate) return;
    const { release, zipballUrl, repo } = pendingUpdate;
    setPendingUpdate(null);
    await runBackgroundActionRef.current("更新补丁资源", (actionId) =>
      invoke<ActionStarted>("install_resource_update", {
        actionId,
        zipballUrl,
        release,
        repo,
      }),
    );
  }, [busy, pendingUpdate]);

  const dismissUpdate = useCallback(() => {
    setPendingUpdate(null);
  }, []);

  useEffect(() => {
    if (checkedResourceUpdateRef.current) {
      return;
    }

    checkedResourceUpdateRef.current = true;

    void (async () => {
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

        setPendingUpdate({
          release: latestVersion,
          zipballUrl: latest.zipball_url,
          repo: manifest.repo,
        });
      } catch (error) {
        appendLog({ level: "warn", message: `检查补丁资源更新失败: ${String(error)}` });
      }
    })();
  }, [appendLog]);

  return { pendingUpdate, approveUpdate, dismissUpdate };
}
