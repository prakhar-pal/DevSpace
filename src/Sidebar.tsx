import { useState, type DragEvent } from "react";
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

function GripIcon() {
  return (
    <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
      <g fill="currentColor">
        <circle cx="6" cy="4" r="1.2" />
        <circle cx="10" cy="4" r="1.2" />
        <circle cx="6" cy="8" r="1.2" />
        <circle cx="10" cy="8" r="1.2" />
        <circle cx="6" cy="12" r="1.2" />
        <circle cx="10" cy="12" r="1.2" />
      </g>
    </svg>
  );
}

function EyeIcon() {
  return (
    <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" strokeWidth={1.3} aria-hidden="true">
      <path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z" />
      <circle cx="8" cy="8" r="2" />
    </svg>
  );
}

function EyeOffIcon() {
  return (
    <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" strokeWidth={1.3} strokeLinecap="round" aria-hidden="true">
      <path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z" />
      <circle cx="8" cy="8" r="2" />
      <line x1="2.5" y1="13.5" x2="13.5" y2="2.5" />
    </svg>
  );
}

interface Props {
  visible: WorkspaceView[];
  hidden: WorkspaceView[];
  selectedId: string | null;
  badges: Record<string, boolean>;
  starting: string[];
  onSelect: (id: string) => void;
  onHide: (id: string) => void;
  onUnhide: (id: string) => void;
  onReorder: (dragId: string, targetId: string, before: boolean) => void;
}

export function Sidebar(props: Props) {
  const { visible, hidden, selectedId, badges, starting } = props;
  const [dragId, setDragId] = useState<string | null>(null);
  const [overId, setOverId] = useState<string | null>(null);
  const [showHidden, setShowHidden] = useState(true);

  const handleDrop = (e: DragEvent<HTMLElement>, targetId: string) => {
    e.preventDefault();
    if (dragId && dragId !== targetId) {
      const rect = e.currentTarget.getBoundingClientRect();
      const before = e.clientY < rect.top + rect.height / 2;
      props.onReorder(dragId, targetId, before);
    }
    setDragId(null);
    setOverId(null);
  };

  return (
    <nav className="sidebar">
      <div className="ws-list">
        {visible.map((w) => (
          <div
            key={w.id}
            className={`ws-row${w.id === selectedId ? " selected" : ""}${
              overId === w.id ? " drag-over" : ""
            }`}
            draggable
            onDragStart={(e) => {
              setDragId(w.id);
              e.dataTransfer.effectAllowed = "move";
            }}
            onDragOver={(e) => {
              e.preventDefault();
              setOverId(w.id);
            }}
            onDragLeave={() => setOverId((o) => (o === w.id ? null : o))}
            onDrop={(e) => handleDrop(e, w.id)}
            onDragEnd={() => {
              setDragId(null);
              setOverId(null);
            }}
          >
            <span className="grip" aria-hidden="true">
              <GripIcon />
            </span>
            <button
              className="ws-main"
              onClick={() => props.onSelect(w.id)}
              title={w.error ?? w.source}
            >
              {starting.includes(w.id) ? (
                <span className="spinner" aria-label="starting" />
              ) : (
                <span className="dot" style={{ background: statusColor(w.state) }} />
              )}
              <span className="ws-name">{w.id}</span>
              {badges[w.id] && <span className="badge" aria-label="unread" />}
            </button>
            <button
              className="ws-action hide"
              title="Hide"
              aria-label={`Hide ${w.id}`}
              onClick={(e) => {
                e.stopPropagation();
                props.onHide(w.id);
              }}
            >
              <EyeOffIcon />
            </button>
          </div>
        ))}
      </div>

      {hidden.length > 0 && (
        <div className="hidden-section">
          <button className="hidden-header" onClick={() => setShowHidden((v) => !v)}>
            {showHidden ? "▾" : "▸"} Hidden ({hidden.length})
          </button>
          {showHidden &&
            hidden.map((w) => (
              <div
                key={w.id}
                className={`ws-row hidden-row${w.id === selectedId ? " selected" : ""}`}
              >
                <button
                  className="ws-main"
                  onClick={() => props.onSelect(w.id)}
                  title={w.error ?? w.source}
                >
                  <span className="dot" style={{ background: statusColor(w.state) }} />
                  <span className="ws-name">{w.id}</span>
                </button>
                <button
                  className="ws-action show"
                  title="Unhide"
                  aria-label={`Unhide ${w.id}`}
                  onClick={(e) => {
                    e.stopPropagation();
                    props.onUnhide(w.id);
                  }}
                >
                  <EyeIcon />
                </button>
              </div>
            ))}
        </div>
      )}
    </nav>
  );
}
