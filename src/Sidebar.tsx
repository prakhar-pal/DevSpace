import { useState, type DragEvent } from "react";
import type { WorkspaceView, WorkspaceState } from "./api";

export function statusColor(state: WorkspaceState): string {
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

function PencilIcon() {
  return (
    <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" strokeWidth={1.3} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M11 2.5l2.5 2.5L6 12.5 3 13l.5-3 7.5-7.5z" />
    </svg>
  );
}

function StopIcon() {
  return (
    <svg viewBox="0 0 16 16" width="11" height="11" fill="currentColor" aria-hidden="true">
      <rect x="3" y="3" width="10" height="10" rx="1.5" />
    </svg>
  );
}

function ReloadIcon() {
  return (
    <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M1 4v4h4" />
      <path d="M3.51 9a6 6 0 101.4-6.4L1 4" />
    </svg>
  );
}

interface Props {
  visible: WorkspaceView[];
  hidden: WorkspaceView[];
  selectedId: string | null;
  badges: Record<string, boolean>;
  starting: string[];
  opened: string[];
  aliases: Record<string, string>;
  onSelect: (id: string) => void;
  onStop: (id: string) => void;
  onReload: (id: string) => void;
  onHide: (id: string) => void;
  onUnhide: (id: string) => void;
  onRename: (id: string) => void;
  onReorder: (dragId: string, targetId: string, before: boolean) => void;
}

export function Sidebar(props: Props) {
  const { visible, hidden, selectedId, badges, starting, opened, aliases } = props;
  const [dragId, setDragId] = useState<string | null>(null);
  const [overId, setOverId] = useState<string | null>(null);
  const [showHidden, setShowHidden] = useState(true);
  const [menu, setMenu] = useState<{ id: string; x: number; y: number; hidden: boolean } | null>(
    null
  );

  // Friendly name if set, else the raw workspace id.
  const displayName = (id: string) => aliases[id] ?? id;

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
            onContextMenu={(e) => {
              e.preventDefault();
              setMenu({ id: w.id, x: e.clientX, y: e.clientY, hidden: false });
            }}
          >
            <span className="grip" aria-hidden="true">
              <GripIcon />
            </span>
            <button
              className="ws-main"
              onClick={() => props.onSelect(w.id)}
              title={aliases[w.id] ? `${w.id} · ${w.source}` : (w.error ?? w.source)}
            >
              {starting.includes(w.id) ? (
                <span className="spinner" aria-label="starting" />
              ) : (
                <span className="dot" style={{ background: statusColor(w.state) }} />
              )}
              <span className="ws-name">{displayName(w.id)}</span>
              {badges[w.id] && <span className="badge" aria-label="unread" />}
            </button>
            {w.state !== "Stopped" && (
              <button
                type="button"
                className="ws-action stop"
                title="Stop devpod"
                aria-label={`Stop ${w.id}`}
                onClick={(e) => {
                  e.stopPropagation();
                  props.onStop(w.id);
                }}
              >
                <StopIcon />
              </button>
            )}
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
                onContextMenu={(e) => {
                  e.preventDefault();
                  setMenu({ id: w.id, x: e.clientX, y: e.clientY, hidden: true });
                }}
              >
                <button
                  className="ws-main"
                  onClick={() => props.onSelect(w.id)}
                  title={aliases[w.id] ? `${w.id} · ${w.source}` : (w.error ?? w.source)}
                >
                  <span className="dot" style={{ background: statusColor(w.state) }} />
                  <span className="ws-name">{displayName(w.id)}</span>
                </button>
              </div>
            ))}
        </div>
      )}

      {menu && (
        <div
          className="ctx-backdrop"
          onClick={() => setMenu(null)}
          onContextMenu={(e) => {
            e.preventDefault();
            setMenu(null);
          }}
        >
          <div
            className="ctx-menu"
            style={{ left: menu.x, top: menu.y }}
            onClick={(e) => e.stopPropagation()}
          >
            <button
              className="ctx-item"
              onClick={() => {
                props.onRename(menu.id);
                setMenu(null);
              }}
            >
              <PencilIcon />
              <span>Set friendly name…</span>
            </button>
            {opened.includes(menu.id) && (
              <button
                className="ctx-item"
                onClick={() => {
                  props.onReload(menu.id);
                  setMenu(null);
                }}
              >
                <ReloadIcon />
                <span>Reload SSH Session</span>
              </button>
            )}
            {menu.hidden ? (
              <button
                className="ctx-item"
                onClick={() => {
                  props.onUnhide(menu.id);
                  setMenu(null);
                }}
              >
                <EyeIcon />
                <span>Show</span>
              </button>
            ) : (
              <button
                className="ctx-item"
                onClick={() => {
                  props.onHide(menu.id);
                  setMenu(null);
                }}
              >
                <EyeOffIcon />
                <span>Hide</span>
              </button>
            )}
          </div>
        </div>
      )}
    </nav>
  );
}
