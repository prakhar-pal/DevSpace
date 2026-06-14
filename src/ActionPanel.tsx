import type { WorkspaceView } from "./api";

interface Props {
  workspace: WorkspaceView;
  onStart: (id: string) => void;
  onDelete: (id: string) => void;
}

const FIELDS: { label: string; value: (w: WorkspaceView) => string }[] = [
  { label: "Provider", value: (w) => w.provider },
  { label: "Source", value: (w) => w.source },
  { label: "Last used", value: (w) => w.last_used },
];

export function ActionPanel({ workspace, onStart, onDelete }: Props) {
  return (
    <div className="action-panel">
      <div className="ap-card">
        <header className="ap-head">
          <h2>{workspace.id}</h2>
          <span className={`ap-state ap-state-${workspace.state.toLowerCase()}`}>
            {workspace.state}
          </span>
        </header>
        <dl className="ap-meta">
          {FIELDS.map((f) => (
            <div className="ap-row" key={f.label}>
              <dt>{f.label}</dt>
              <dd>{f.value(workspace) || "—"}</dd>
            </div>
          ))}
        </dl>
        <div className="ap-actions">
          <button className="btn btn-primary" onClick={() => onStart(workspace.id)}>
            Start
          </button>
          <button className="btn btn-danger" onClick={() => onDelete(workspace.id)}>
            Delete
          </button>
        </div>
      </div>
    </div>
  );
}
