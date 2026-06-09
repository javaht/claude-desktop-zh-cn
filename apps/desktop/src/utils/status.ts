import type { EnvironmentReport } from "../types";

export function statusText(env: EnvironmentReport | null) {
  if (!env) return "等待检测";
  if (!env.resourcesOk) return "资源异常";
  if (!env.claudePath) return "未找到 Claude";
  return "可执行";
}

export function levelLabel(level: string) {
  if (level === "error") return "错误";
  if (level === "warn") return "警告";
  return "日志";
}

export function compactPath(path?: string | null) {
  if (!path) return "-";
  const parts = path.split(/[\\/]+/).filter(Boolean);
  return parts[parts.length - 1] ?? path;
}
