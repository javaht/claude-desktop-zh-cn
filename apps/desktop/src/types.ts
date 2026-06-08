export type EnvironmentReport = {
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

export type LogEvent = {
  level: "info" | "warn" | "error" | string;
  message: string;
};

export type ActionStarted = {
  actionId: string;
};

export type ActionFinished = {
  actionId: string;
  action: string;
  ok: boolean;
  error?: string | null;
};

export type ActionLogDrain = {
  logs: LogEvent[];
  nextOffset: number;
  finished?: ActionFinished | null;
};

export type ResourceReleaseManifest = {
  repo: string;
  release: string;
};

export type GitHubRelease = {
  tag_name: string;
  html_url: string;
  zipball_url: string;
};

export type Language = "zh-CN" | "zh-TW" | "zh-HK";
export type PatchMode = "safe" | "official";
