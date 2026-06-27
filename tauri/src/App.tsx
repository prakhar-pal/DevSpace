import { useEffect, useMemo, useRef, useState } from "react";
import { Sidebar } from "./components/Sidebar";
import { ActionPanel } from "./components/ActionPanel";
import { Terminal } from "./components/Terminal";
import { StartLog } from "./components/StartLog";
import { RenameModal } from "./components/RenameModal";
import { GuideModal } from "./components/GuideModal";
import {
  onWorkspacesUpdated,
  onPodBadge,
  startWorkspace,
  stopWorkspace,
  disconnectPty,
  loadLayout,
  saveLayout,
  type WorkspaceView,
} from "./api";
import "./App.css";

export default function App() {
  const [workspaces, setWorkspaces] = useState<WorkspaceView[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [badges, setBadges] = useState<Record<string, boolean>>({});
  const [opened, setOpened] = useState<string[]>([]);
  // Workspaces with a running `devpod up` (showing the startup log stream).
  const [starting, setStarting] = useState<string[]>([]);
  // Workspaces whose SSH session ended but devpod is still shutting down.
  const [shuttingDown, setShuttingDown] = useState<string[]>([]);
  // Tracks the reload sequence number for each workspace.
  const [reloads, setReloads] = useState<Record<string, number>>({});
  const [sidebarOpen, setSidebarOpen] = useState(true);
  // Sidebar layout, persisted in a backend JSON file (load on mount, save on
  // change). order = drag order; hidden = hidden set; aliases = friendly names.
  const [order, setOrder] = useState<string[]>([]);
  const [hidden, setHidden] = useState<string[]>([]);
  const [aliases, setAliases] = useState<Record<string, string>>({});
  // Whether the sidebar's "Hidden" section is collapsed (persisted).
  const [hiddenCollapsed, setHiddenCollapsed] = useState(false);
  // Workspace id currently being renamed (drives the friendly-name modal).
  const [renaming, setRenaming] = useState<string | null>(null);
  // Whether the in-app guide modal is open.
  const [guideOpen, setGuideOpen] = useState(false);

  const selectedIdRef = useRef<string | null>(null);
  const visibleRef = useRef<WorkspaceView[]>([]);
  // Tracks whether any modal is open, so the global keyboard shortcuts below
  // don't fire behind an overlay. Updated via an effect (the keydown listener
  // is registered once and reads this ref).
  const modalOpenRef = useRef(false);
  // Gate saving until the initial load has applied, so we don't overwrite the
  // saved file with empty arrays before loadLayout resolves.
  const layoutLoaded = useRef(false);

  useEffect(() => {
    selectedIdRef.current = selectedId;
  }, [selectedId]);

  useEffect(() => {
    modalOpenRef.current = guideOpen || renaming !== null;
  }, [guideOpen, renaming]);

  const select = (id: string) => {
    setSelectedId(id);
    setBadges((b) => ({ ...b, [id]: false }));
  };

  useEffect(() => {
    // Load persisted sidebar layout once.
    loadLayout()
      .then((l) => {
        setOrder(l.order ?? []);
        setHidden(l.hidden ?? []);
        setAliases(l.aliases ?? {});
        setHiddenCollapsed(l.hidden_collapsed ?? false);
      })
      .catch(() => {})
      .finally(() => {
        layoutLoaded.current = true;
      });
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

  // Persist layout on change (after the initial load has applied).
  useEffect(() => {
    if (!layoutLoaded.current) return;
    saveLayout(order, hidden, aliases, hiddenCollapsed).catch(() => {});
  }, [order, hidden, aliases, hiddenCollapsed]);

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
      // An open modal owns the keyboard; don't act behind it.
      if (modalOpenRef.current) return;
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

  // Track opened terminals; automatically open and SSH into any running workspace.
  useEffect(() => {
    const runningIds = workspaces.filter((w) => w.state === "Running").map((w) => w.id);
    setOpened((prev) => {
      const next = [...prev];
      let changed = false;
      for (const id of runningIds) {
        if (!next.includes(id)) {
          next.push(id);
          changed = true;
        }
      }
      if (selected && selected.state === "Running" && !next.includes(selected.id)) {
        next.push(selected.id);
        changed = true;
      }
      return changed ? next : prev;
    });
  }, [workspaces, selected]);

  // Drop a terminal only when its pod is explicitly Stopped or gone — NOT on a
  // transient "Unknown"/"Loading" status blip.
  useEffect(() => {
    setOpened((prev) =>
      prev.filter((id) => {
        const w = workspaces.find((x) => x.id === id);
        return w !== undefined && w.state !== "Stopped";
      })
    );
    // Also clear shuttingDown once the workspace is confirmed Stopped.
    setShuttingDown((prev) =>
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

  // Set/clear a workspace's friendly name. Empty or equal-to-id clears it.
  const setAlias = (id: string, name: string) => {
    setAliases((prev) => {
      const next = { ...prev };
      if (!name || name === id) delete next[id];
      else next[id] = name;
      return next;
    });
  };

  const start = (id: string) => {
    startWorkspace(id).catch(() => {});
    setStarting((s) => (s.includes(id) ? s : [...s, id]));
    select(id);
  };

  const stop = (id: string) => {
    stopWorkspace(id).catch(() => {});
  };

  const reload = async (id: string) => {
    await disconnectPty(id).catch(() => {});
    setReloads((prev) => ({ ...prev, [id]: (prev[id] || 0) + 1 }));
  };

  const onExited = (id: string) => {
    setOpened((prev) => prev.filter((x) => x !== id));
    setShuttingDown((prev) => (prev.includes(id) ? prev : [...prev, id]));
    select(id);
    stop(id);
  };

  // `devpod up` finished (its PTY closed). Only NOW leave the "starting" state —
  // not when status flips to Running, which can happen while `up` is still
  // streaming and would mount the SSH terminal over the live startup session.
  // Optimistically mark Running so the terminal mounts immediately; the next
  // poll confirms (or corrects) it.
  const onUpFinished = (id: string) => {
    setStarting((s) => s.filter((x) => x !== id));
    setWorkspaces((ws) => ws.map((w) => (w.id === id ? { ...w, state: "Running" } : w)));
  };

  // Don't show the SSH terminal for a pod that's still starting — its PTY
  // session is the live `devpod up` log, not a shell.
  const runningTerminals = Array.from(
    new Set([...opened, ...(selected?.state === "Running" ? [selected.id] : [])])
  ).filter((id) => {
    const w = workspaces.find((x) => x.id === id);
    return w !== undefined && w.state !== "Stopped" && !starting.includes(id) && !shuttingDown.includes(id);
  });

  const selectedStarting = !!selected && starting.includes(selected.id);
  const selectedShuttingDown = !!selected && shuttingDown.includes(selected.id);
  const selectedHasTerminal =
    !!selected && !selectedStarting && !selectedShuttingDown && runningTerminals.includes(selected.id);

  return (
    <div className="flex h-screen font-sans">
      {sidebarOpen && (
        <Sidebar
          visible={visibleWs}
          hidden={hiddenWs}
          selectedId={selectedId}
          badges={badges}
          starting={starting}
          opened={opened}
          aliases={aliases}
          hiddenCollapsed={hiddenCollapsed}
          onToggleHiddenCollapsed={() => setHiddenCollapsed((v) => !v)}
          onOpenGuide={() => setGuideOpen(true)}
          onSelect={select}
          onStop={stop}
          onReload={reload}
          onHide={hide}
          onUnhide={unhide}
          onRename={setRenaming}
          onReorder={reorder}
        />
      )}
      <main className="flex-1 flex flex-col bg-[#111] text-[#eee] min-w-0">
        {!selected && <div className="m-auto text-[#777]">Select a workspace</div>}
        {selected && !selectedHasTerminal && !selectedStarting && !selectedShuttingDown && (
          <ActionPanel workspace={selected} onStart={start} />
        )}
        {/* Startup logs: keep all starting pods mounted in a hidden stack so
            switching workspaces doesn't lose the buffered `devpod up` output. */}
        <div
          className="flex-1 min-h-0 min-w-0 flex-col"
          style={{ display: selectedStarting ? "flex" : "none" }}
        >
          {starting.map((id) => (
            <div
              key={id}
              className="flex-1 min-h-0 min-w-0 flex-col"
              style={{ display: id === selectedId ? "flex" : "none" }}
            >
              <StartLog
                podId={id}
                visible={id === selectedId}
                onFinished={() => onUpFinished(id)}
              />
            </div>
          ))}
        </div>
        {/* Shutdown logs: shown after the user types `exit` in the SSH terminal
            until devpod finishes stopping the container. */}
        <div
          className="flex-1 min-h-0 min-w-0 flex-col"
          style={{ display: selectedShuttingDown ? "flex" : "none" }}
        >
          {shuttingDown.map((id) => (
            <div
              key={id}
              className="flex-1 min-h-0 min-w-0 flex-col"
              style={{ display: id === selectedId ? "flex" : "none" }}
            >
              <StartLog
                podId={id}
                visible={id === selectedId}
                label={`${id} — shutting down…`}
              />
            </div>
          ))}
        </div>
        <div className="flex-1 min-h-0 min-w-0 flex-col" style={{ display: selectedHasTerminal ? "flex" : "none" }}>
          {runningTerminals.map((id) => (
            <div
              key={id}
              className="flex-1 min-h-0 min-w-0 flex-col"
              style={{ display: id === selectedId ? "flex" : "none" }}
            >
              <Terminal
                podId={id}
                visible={id === selectedId}
                reloadNonce={reloads[id]}
                onExited={() => onExited(id)}
              />
            </div>
          ))}
        </div>
      </main>
      {renaming && (
        <RenameModal
          workspaceId={renaming}
          initialName={aliases[renaming] ?? renaming}
          onSubmit={(name) => {
            setAlias(renaming, name);
            setRenaming(null);
          }}
          onCancel={() => setRenaming(null)}
        />
      )}
      {guideOpen && <GuideModal onClose={() => setGuideOpen(false)} />}
    </div>
  );
}
