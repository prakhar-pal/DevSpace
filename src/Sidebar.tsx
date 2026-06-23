import { useState, type DragEvent } from "react";
import { clsx } from "clsx";
import { openIde } from "./api";
import type { WorkspaceView, WorkspaceState } from "./api";

export function statusColor(state: WorkspaceState): string {
  switch (state) {
    case "Running":
      return "green";
    case "Stopped":
      return "grey";
    case "Busy":
      return "amber";
    case "Loading":
      // Status not resolved yet — neutral, not an error.
      return "grey";
    default:
      return "red";
  }
}


function EyeIcon() {
  return (
    <svg
      viewBox="0 0 16 16"
      width="13"
      height="13"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.3}
      aria-hidden="true"
    >
      <path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z" />
      <circle cx="8" cy="8" r="2" />
    </svg>
  );
}

function EyeOffIcon() {
  return (
    <svg
      viewBox="0 0 16 16"
      width="13"
      height="13"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.3}
      strokeLinecap="round"
      aria-hidden="true"
    >
      <path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z" />
      <circle cx="8" cy="8" r="2" />
      <line x1="2.5" y1="13.5" x2="13.5" y2="2.5" />
    </svg>
  );
}

function PencilIcon() {
  return (
    <svg
      viewBox="0 0 16 16"
      width="13"
      height="13"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.3}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M11 2.5l2.5 2.5L6 12.5 3 13l.5-3 7.5-7.5z" />
    </svg>
  );
}

function StopIcon() {
  return (
    <svg
      viewBox="0 0 16 16"
      width="11"
      height="11"
      fill="currentColor"
      aria-hidden="true"
    >
      <rect x="3" y="3" width="10" height="10" rx="1.5" />
    </svg>
  );
}

function ReloadIcon() {
  return (
    <svg
      viewBox="0 0 16 16"
      width="12"
      height="12"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M1 4v4h4" />
      <path d="M3.51 9a6 6 0 101.4-6.4L1 4" />
    </svg>
  );
}

function DotsVerticalIcon() {
  return (
    <svg
      viewBox="0 0 16 16"
      width="14"
      height="14"
      fill="currentColor"
      aria-hidden="true"
    >
      <circle cx="8" cy="3" r="1.5" />
      <circle cx="8" cy="8" r="1.5" />
      <circle cx="8" cy="13" r="1.5" />
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
  const { visible, hidden, selectedId, badges, starting, opened, aliases } =
    props;
  const [dragId, setDragId] = useState<string | null>(null);
  const [overId, setOverId] = useState<string | null>(null);
  const [menu, setMenu] = useState<{
    id: string;
    x: number;
    y: number;
    hidden: boolean;
  } | null>(null);

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
    <nav className="w-[240px] border-r border-[#2a2a2a] bg-[#18181b] flex flex-col">
      <div className="flex-1 overflow-y-auto pt-2">
        {visible.map((w) => (
          <div
            key={w.id}
            className={clsx("ws-row group flex items-center mx-2 my-[2px] rounded-md transition-colors duration-150", w.id === selectedId && "bg-[#3f3f46]", overId === w.id && "shadow-[inset_0_0_0_1px_rgba(59,130,246,0.5)] bg-blue-500/10")}
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
            <button
              className={clsx("flex ml-1.5 items-center gap-2 flex-1 min-w-0 p-2 pl-1 border-none bg-transparent cursor-pointer text-left text-[13px]", w.id === selectedId ? "text-white font-medium" : "text-[#d4d4d8]")}
              onClick={() => props.onSelect(w.id)}
              title={
                aliases[w.id] ? `${w.id} · ${w.source}` : (w.error ?? w.source)
              }
            >
              {starting.includes(w.id) ? (
                <span
                  className="w-2.5 h-2.5 flex-none rounded-full border-2 border-[#444] border-t-green-400 animate-spin"
                  aria-label="starting"
                />
              ) : w.state === "Loading" ? (
                <span
                  className="w-2.5 h-2.5 flex-none rounded-full border-2 border-[#444] border-t-[#888] animate-spin"
                  aria-label="fetching status"
                />
              ) : (
                <span
                  className="w-2.5 h-2.5 rounded-full flex-none"
                  style={{ background: statusColor(w.state) }}
                />
              )}
              <span className="flex-1 overflow-hidden truncate whitespace-nowrap">
                {displayName(w.id)}
              </span>
              {badges[w.id] && (
                <span
                  className="w-2 h-2 rounded-full bg-blue-500 flex-none"
                  aria-label="unread"
                />
              )}
            </button>
            {w.state !== "Stopped" && (
              <button
                type="button"
                className={clsx("flex items-center justify-center flex-none w-[26px] h-[26px] mr-1.5 p-0 border-none bg-transparent rounded-md cursor-pointer text-[#9a9a9a] transition-all duration-100 hover:text-red-400 hover:bg-red-400/15", w.id === selectedId ? "opacity-100" : "opacity-0 group-hover:opacity-100")}
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
            <button
              type="button"
              className={clsx("flex items-center justify-center flex-none w-[26px] h-[26px] p-0 border-none bg-transparent rounded-md cursor-pointer text-[#9a9a9a] transition-all duration-100 hover:text-white hover:bg-white/10", w.state === "Stopped" && "mr-1.5", w.id === selectedId ? "opacity-100" : "opacity-0 group-hover:opacity-100")}
              title="More options"
              aria-label={`Options for ${w.id}`}
              onClick={(e) => {
                e.stopPropagation();
                setMenu({
                  id: w.id,
                  x: e.clientX,
                  y: e.clientY,
                  hidden: false,
                });
              }}
            >
              <DotsVerticalIcon />
            </button>
          </div>
        ))}
      </div>

      {hidden.length > 0 && (
        <div className="border-t border-[#2a2a2a] mt-auto pb-2">
          <div className="flex items-center gap-1.5 w-full px-3 pt-3 pb-2 text-[#777] text-left text-[11px] uppercase tracking-wider font-semibold">
            Hidden ({hidden.length})
          </div>
          {hidden.map((w) => (
            <div
              key={w.id}
              className={clsx("ws-row group flex items-center mx-2 my-[2px] rounded-md transition-colors duration-150", w.id === selectedId && "bg-[#3f3f46]")}
              onContextMenu={(e) => {
                e.preventDefault();
                setMenu({ id: w.id, x: e.clientX, y: e.clientY, hidden: true });
              }}
            >
              <button
                className={clsx("flex items-center gap-2 flex-1 min-w-0 py-2 pr-2 pl-3 border-none bg-transparent cursor-pointer text-left text-[13px]", w.id === selectedId ? "text-white font-medium" : "text-[#888]")}
                onClick={() => props.onSelect(w.id)}
                title={
                  aliases[w.id]
                    ? `${w.id} · ${w.source}`
                    : (w.error ?? w.source)
                }
              >
                {w.state === "Loading" ? (
                  <span
                    className="w-2.5 h-2.5 flex-none rounded-full border-2 border-[#444] border-t-[#888] animate-spin"
                    aria-label="fetching status"
                  />
                ) : (
                  <span
                    className="w-2.5 h-2.5 rounded-full flex-none"
                    style={{ background: statusColor(w.state) }}
                  />
                )}
                <span className="flex-1 overflow-hidden truncate whitespace-nowrap">
                  {displayName(w.id)}
                </span>
              </button>
              <button
                type="button"
                className={clsx("flex items-center justify-center flex-none w-[26px] h-[26px] mr-1.5 p-0 border-none bg-transparent rounded-md cursor-pointer text-[#9a9a9a] transition-all duration-100 hover:text-white hover:bg-white/10", w.id === selectedId ? "opacity-100" : "opacity-0 group-hover:opacity-100")}
                title="More options"
                aria-label={`Options for ${w.id}`}
                onClick={(e) => {
                  e.stopPropagation();
                  setMenu({
                    id: w.id,
                    x: e.clientX,
                    y: e.clientY,
                    hidden: true,
                  });
                }}
              >
                <DotsVerticalIcon />
              </button>
            </div>
          ))}
        </div>
      )}

      {menu && (
        <div
          className="fixed inset-0 z-[1000]"
          onClick={() => setMenu(null)}
          onContextMenu={(e) => {
            e.preventDefault();
            setMenu(null);
          }}
        >
          <div
            className="fixed min-w-[180px] bg-[#232323] border border-[#3a3a3a] rounded-lg p-1 shadow-2xl"
            style={{ left: menu.x, top: menu.y }}
            onClick={(e) => e.stopPropagation()}
          >
            <button
              className="group/item flex items-center gap-[9px] w-full px-3 py-2 border-none bg-transparent text-[#ddd] cursor-pointer text-left font-inherit rounded hover:bg-blue-600 hover:text-white text-[13px]"
              onClick={() => {
                props.onRename(menu.id);
                setMenu(null);
              }}
            >
              <div className="flex-none text-[#9a9a9a] group-hover/item:text-white">
                <PencilIcon />
              </div>
              <span>Set friendly name…</span>
            </button>
            {opened.includes(menu.id) && (
              <button
                className="group/item flex items-center gap-[9px] w-full px-3 py-2 border-none bg-transparent text-[#ddd] cursor-pointer text-left font-inherit rounded hover:bg-blue-600 hover:text-white text-[13px]"
                onClick={() => {
                  props.onReload(menu.id);
                  setMenu(null);
                }}
              >
                <div className="flex-none text-[#9a9a9a] group-hover/item:text-white">
                  <ReloadIcon />
                </div>
                <span>Reload SSH Session</span>
              </button>
            )}
            <div style={{ height: 1, background: '#2a2a2a', margin: '4px 0' }} />
            <button
              className="group/item flex items-center gap-[9px] w-full px-3 py-2 border-none bg-transparent text-[#ddd] cursor-pointer text-left font-inherit rounded hover:bg-blue-600 hover:text-white text-[13px]"
              onClick={() => {
                openIde(menu.id, "zed");
                setMenu(null);
              }}
            >
              <div className="flex-none text-[#9a9a9a] group-hover/item:text-white">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>
              </div>
              <span>Open in Zed</span>
            </button>
            <div style={{ height: 1, background: '#2a2a2a', margin: '4px 0' }} />
            {menu.hidden ? (
              <button
                className="group/item flex items-center gap-[9px] w-full px-3 py-2 border-none bg-transparent text-[#ddd] cursor-pointer text-left font-inherit rounded hover:bg-blue-600 hover:text-white text-[13px]"
                onClick={() => {
                  props.onUnhide(menu.id);
                  setMenu(null);
                }}
              >
                <div className="flex-none text-[#9a9a9a] group-hover/item:text-white">
                  <EyeIcon />
                </div>
                <span>Show</span>
              </button>
            ) : (
              <button
                className="group/item flex items-center gap-[9px] w-full px-3 py-2 border-none bg-transparent text-[#ddd] cursor-pointer text-left font-inherit rounded hover:bg-blue-600 hover:text-white text-[13px]"
                onClick={() => {
                  props.onHide(menu.id);
                  setMenu(null);
                }}
              >
                <div className="flex-none text-[#9a9a9a] group-hover/item:text-white">
                  <EyeOffIcon />
                </div>
                <span>Hide</span>
              </button>
            )}
          </div>
        </div>
      )}
    </nav>
  );
}
