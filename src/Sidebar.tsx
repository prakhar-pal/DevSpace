import type { WorkspaceView } from "./api";

export function statusColor(state: string): string {
  switch (state) {
    case "Running":
      return "green";
    case "Stopped":
      return "grey";
    case "Busy":
      return "amber";
    case "Pending":
      // Status not resolved yet — neutral, not an error.
      return "grey";
    default:
      return "red";
  }
}

function PlayIcon() {
  return (
    <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">
      <path d="M5 3.5v9l7-4.5z" fill="currentColor" />
    </svg>
  );
}

function StopIcon() {
  return (
    <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">
      <rect x="4" y="4" width="8" height="8" rx="1" fill="currentColor" />
    </svg>
  );
}

interface Props {
  workspaces: WorkspaceView[];
  selectedId: string | null;
  badges: Record<string, boolean>;
  onSelect: (id: string) => void;
  onStart: (id: string) => void;
  onStop: (id: string) => void;
}

export function Sidebar({ workspaces, selectedId, badges, onSelect, onStart, onStop }: Props) {
  return (
    <nav className="sidebar">
      {workspaces.map((w) => {
        const running = w.state === "Running";
        return (
          <div key={w.id} className={`ws-row${w.id === selectedId ? " selected" : ""}`}>
            <button
              className="ws-main"
              onClick={() => onSelect(w.id)}
              title={w.error ?? w.source}
            >
              <span className="dot" style={{ background: statusColor(w.state) }} />
              <span className="ws-name">{w.id}</span>
              {badges[w.id] && <span className="badge" aria-label="unread" />}
            </button>
            <button
              className={`ws-action ${running ? "stop" : "start"}`}
              title={running ? "Stop" : "Start"}
              aria-label={`${running ? "Stop" : "Start"} ${w.id}`}
              onClick={(e) => {
                e.stopPropagation();
                (running ? onStop : onStart)(w.id);
              }}
            >
              {running ? <StopIcon /> : <PlayIcon />}
            </button>
          </div>
        );
      })}
    </nav>
  );
}
