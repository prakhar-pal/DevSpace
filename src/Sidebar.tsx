import type { WorkspaceView } from "./api";

export function statusColor(state: string): string {
  switch (state) {
    case "Running":
      return "green";
    case "Stopped":
      return "grey";
    case "Busy":
      return "amber";
    default:
      return "red";
  }
}

interface Props {
  workspaces: WorkspaceView[];
  selectedId: string | null;
  badges: Record<string, boolean>;
  onSelect: (id: string) => void;
}

export function Sidebar({ workspaces, selectedId, badges, onSelect }: Props) {
  return (
    <nav className="sidebar">
      {workspaces.map((w) => (
        <button
          key={w.id}
          className={`ws-row${w.id === selectedId ? " selected" : ""}`}
          onClick={() => onSelect(w.id)}
          title={w.error ?? w.source}
        >
          <span className="dot" style={{ background: statusColor(w.state) }} />
          <span className="ws-name">{w.id}</span>
          {badges[w.id] && <span className="badge" aria-label="unread" />}
        </button>
      ))}
    </nav>
  );
}
