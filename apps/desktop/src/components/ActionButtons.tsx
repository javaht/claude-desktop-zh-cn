import { CheckCircle2, Eraser, RotateCcw, Wrench, XCircle } from "lucide-react";

type ActionButtonsProps = {
  canRun: boolean;
  busy: string | null;
  onRestore: () => void;
  onEnableAutoUpdates: () => void;
  onDisableAutoUpdates: () => void;
  onSyncSkills: () => void;
  onUnsyncSkills: () => void;
};

export function ActionButtons({
  canRun,
  busy,
  onRestore,
  onEnableAutoUpdates,
  onDisableAutoUpdates,
  onSyncSkills,
  onUnsyncSkills,
}: ActionButtonsProps) {
  return (
    <section className="panel">
      <div className="panelHeader">
        <h2>维护操作</h2>
      </div>

      <div className="actions">
        <button disabled={!canRun} onClick={onRestore}>
          <RotateCcw />
          恢复 / 卸载补丁
        </button>
        <button disabled={Boolean(busy)} onClick={onEnableAutoUpdates}>
          <CheckCircle2 />
          允许自动更新
        </button>
        <button disabled={Boolean(busy)} onClick={onDisableAutoUpdates}>
          <XCircle />
          停止自动更新
        </button>
        <button disabled={Boolean(busy)} onClick={onSyncSkills}>
          <Wrench />
          同步 CC Switch skills
        </button>
        <button disabled={Boolean(busy)} onClick={onUnsyncSkills}>
          <Eraser />
          删除 skills 同步
        </button>
      </div>
    </section>
  );
}
