import { useCallback, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { EnvironmentReport } from "../types";

export function useEnvironment() {
  const [env, setEnv] = useState<EnvironmentReport | null>(null);

  const detectEnvironment = useCallback(async () => {
    const report = await invoke<EnvironmentReport>("detect_environment");
    setEnv(report);
    return report;
  }, []);

  return { env, detectEnvironment };
}
