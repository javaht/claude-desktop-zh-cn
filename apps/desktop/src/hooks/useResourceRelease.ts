import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { ActionStarted, GitHubRelease, LogEvent, ResourceReleaseManifest } from "../types";
import { compareVersions, normalizeVersion } from "../utils/version";

export function useResourceRelease(
  appendLog: (entry: LogEvent) => void,
  runBackgroundAction: (
    name: string,
    fn: (actionId: string) => Promise<ActionStarted>,
  ) => Promise<void>,
) {
  const checkedResourceUpdateRef = useRef(false);

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
    })();
  }, [appendLog, runBackgroundAction]);
}
