import { useEffect, useMemo, useRef, useState } from "react";
import { Sidebar } from "./Sidebar";
import { ActionPanel } from "./ActionPanel";
import { Terminal } from "./Terminal";
import { StartLog } from "./StartLog";
import {
  onWorkspacesUpdated,
  onPodBadge,
  startWorkspace,
  type WorkspaceView,
} from "./api";
import "./App.css";

const ORDER_KEY = "devspace.order";
const HIDDEN_KEY = "devspace.hidden";

function loadIds(key: string): string[] {
  try {
    const v = JSON.parse(localStorage.getItem(key) || "[]");
    return Array.isArray(v) ? v.filter((x) => typeof x === "string") : [];
  } catch {
    return [];
  }
}

export default function App() {
  const [workspaces, setWorkspaces] = useState<WorkspaceView[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [badges, setBadges] = useState<Record<string, boolean>>({});
  const [opened, setOpened] = useState<string[]>([]);
  // Workspaces with a running `devpod up` (showing the startup log stream).
  const [starting, setStarting] = useState<string[]>([]);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  // User-defined sidebar order and hidden set, persisted across launches.
  const [order, setOrder] = useState<string[]>(() => loadIds(ORDER_KEY));
  const [hidden, setHidden] = useState<string[]>(() => loadIds(HIDDEN_KEY));

  const selectedIdRef = useRef<string | null>(null);
  const visibleRef = useRef<WorkspaceView[]>([]);

  useEffect(() => {
    selectedIdRef.current = selectedId;
  }, [selectedId]);

  const select = (id: string) => {
    setSelectedId(id);
    setBadges((b) => ({ ...b, [id]: false }));
  };

  useEffect(() => {
    // The background poller is the single source: it emits the list (names)
    // immediately after `devpod list`, then again once statuses resolve. No
    // redundant initial invoke that would double the cold-start devpod load.
    const subs = [
      onWorkspacesUpdated(setWorkspaces),
      onPodBadge((podId) =>
        setBadges((b) =>
          podId === selectedIdRef.current ? b : { ...b, [podId]: true }
        )
      ),
    ];
    return () => {
      subs.forEach((p) => p.then((un) => un()));
    };
  }, []);

  // Persist order and hidden set.
  useEffect(() => {
    localStorage.setItem(ORDER_KEY, JSON.stringify(order));
  }, [order]);
  useEffect(() => {
    localStorage.setItem(HIDDEN_KEY, JSON.stringify(hidden));
  }, [hidden]);

  // Keep `order` canonical: append new workspaces, drop removed ones; prune
  // hidden ids that no longer exist.
  useEffect(() => {
    const ids = workspaces.map((w) => w.id);
    setOrder((prev) => {
      const kept = prev.filter((id) => ids.includes(id));
      const added = ids.filter((id) => !prev.includes(id));
      if (added.length === 0 && kept.length === prev.length) return prev;
      return [...kept, ...added];
    });
    setHidden((prev) => {
      const next = prev.filter((id) => ids.includes(id));
      return next.length === prev.length ? prev : next;
    });
  }, [workspaces]);

  const wsById = useMemo(
    () => new Map(workspaces.map((w) => [w.id, w])),
    [workspaces]
  );

  // Display order = saved order first, then any not-yet-ordered ids (avoids a
  // blank frame before the normalize effect runs).
  const displayIds = useMemo(() => {
    const inOrder = order.filter((id) => wsById.has(id));
    const rest = workspaces.map((w) => w.id).filter((id) => !order.includes(id));
    return [...inOrder, ...rest];
  }, [order, workspaces, wsById]);

  const hiddenSet = useMemo(() => new Set(hidden), [hidden]);
  const visibleWs = displayIds
    .filter((id) => !hiddenSet.has(id))
    .map((id) => wsById.get(id)!)
    .filter(Boolean);
  const hiddenWs = displayIds
    .filter((id) => hiddenSet.has(id))
    .map((id) => wsById.get(id)!)
    .filter(Boolean);

  useEffect(() => {
    visibleRef.current = visibleWs;
  });

  // Keyboard shortcuts: Cmd+1..9 selects the Nth VISIBLE workspace; Cmd+B
  // toggles the sidebar. Capture phase + stopPropagation so a focused terminal
  // doesn't also receive the keystroke.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === "b" || e.key === "B") {
        e.preventDefault();
        e.stopPropagation();
        setSidebarOpen((v) => !v);
        return;
      }
      if (e.key >= "1" && e.key <= "9") {
        const ws = visibleRef.current;
        const idx = Number(e.key) - 1;
        if (ws[idx]) {
          e.preventDefault();
          e.stopPropagation();
          const id = ws[idx].id;
          setSelectedId(id);
          setBadges((b) => ({ ...b, [id]: false }));
        }
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, []);

  const selected = workspaces.find((w) => w.id === selectedId) ?? null;

  // Track opened terminals; remember a running pod the moment it's selected.
  useEffect(() => {
    if (selected?.state === "Running") {
      setOpened((prev) => (prev.includes(selected.id) ? prev : [...prev, selected.id]));
    }
  }, [selectedId, selected?.state]);

  // Drop a terminal only when its pod is explicitly Stopped or gone — NOT on a
  // transient "Unknown"/"Pending" status blip.
  useEffect(() => {
    setOpened((prev) =>
      prev.filter((id) => {
        const w = workspaces.find((x) => x.id === id);
        return w !== undefined && w.state !== "Stopped";
      })
    );
  }, [workspaces]);

  // Terminal width changes when the sidebar toggles; nudge a refit.
  useEffect(() => {
    const raf = requestAnimationFrame(() => window.dispatchEvent(new Event("resize")));
    return () => cancelAnimationFrame(raf);
  }, [sidebarOpen]);

  const reorder = (dragId: string, targetId: string, before: boolean) => {
    setOrder((prev) => {
      if (dragId === targetId) return prev;
      const arr = prev.filter((id) => id !== dragId);
      let idx = arr.indexOf(targetId);
      if (idx === -1) return prev;
      if (!before) idx += 1;
      arr.splice(idx, 0, dragId);
      return arr;
    });
  };

  const hide = (id: string) => setHidden((prev) => (prev.includes(id) ? prev : [...prev, id]));
  const unhide = (id: string) => setHidden((prev) => prev.filter((x) => x !== id));

  const start = (id: string) => {
    startWorkspace(id).catch(() => {});
    setStarting((s) => (s.includes(id) ? s : [...s, id]));
    select(id);
  };

  // Once a workspace is Running, it's no longer "starting" — switch from the
  // startup log to the interactive terminal.
  useEffect(() => {
    setStarting((s) =>
      s.filter((id) => {
        const w = workspaces.find((x) => x.id === id);
        return w !== undefined && w.state !== "Running";
      })
    );
  }, [workspaces]);

  const runningTerminals = Array.from(
    new Set([...opened, ...(selected?.state === "Running" ? [selected.id] : [])])
  ).filter((id) => {
    const w = workspaces.find((x) => x.id === id);
    return w !== undefined && w.state !== "Stopped";
  });

  const selectedHasTerminal = !!selected && runningTerminals.includes(selected.id);
  const selectedStarting =
    !!selected && selected.state !== "Running" && starting.includes(selected.id);

  return (
    <div className="app">
      {sidebarOpen && (
        <Sidebar
          visible={visibleWs}
          hidden={hiddenWs}
          selectedId={selectedId}
          badges={badges}
          onSelect={select}
          onHide={hide}
          onUnhide={unhide}
          onReorder={reorder}
        />
      )}
      <main className="main">
        {!selected && <div className="empty">Select a workspace</div>}
        {selected && !selectedHasTerminal && !selectedStarting && (
          <ActionPanel workspace={selected} onStart={start} />
        )}
        {selected && selectedStarting && <StartLog key={selected.id} podId={selected.id} />}
        <div className="term-stack" style={{ display: selectedHasTerminal ? "flex" : "none" }}>
          {runningTerminals.map((id) => (
            <div
              key={id}
              className="term-pane"
              style={{ display: id === selectedId ? "flex" : "none" }}
            >
              <Terminal podId={id} visible={id === selectedId} />
            </div>
          ))}
        </div>
      </main>
    </div>
  );
}
