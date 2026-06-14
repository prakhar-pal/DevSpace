import type { WorkspaceView } from "./api";

interface Props {
  workspace: WorkspaceView;
  onStart: (id: string) => void;
  onDelete: (id: string) => void;
}

export function ActionPanel({ workspace, onStart, onDelete }: Props) {
  return (
    <div className="action-panel">
      <h2>{workspace.id}</h2>
      <dl>
        <dt>Provider</dt>
        <dd>{workspace.provider}</dd>
        <dt>Source</dt>
        <dd>{workspace.source}</dd>
        <dt>Last used</dt>
        <dd>{workspace.last_used}</dd>
        <dt>State</dt>
        <dd>{workspace.state}</dd>
      </dl>
      <div className="actions">
        <button onClick={() => onStart(workspace.id)}>Start</button>
        <button className="danger" onClick={() => onDelete(workspace.id)}>Delete</button>
      </div>
    </div>
  );
}
