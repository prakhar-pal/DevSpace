import { useEffect, useRef, useState } from "react";
import { Sidebar } from "./Sidebar";
import { ActionPanel } from "./ActionPanel";
import { Terminal } from "./Terminal";
import {
  listWorkspaces,
  onWorkspacesUpdated,
  onPodBadge,
  startWorkspace,
  stopWorkspace,
  deleteWorkspace,
  type WorkspaceView,
} from "./api";
import "./App.css";

export default function App() {
  const [workspaces, setWorkspaces] = useState<WorkspaceView[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [badges, setBadges] = useState<Record<string, boolean>>({});
  // Pods whose terminal has been opened this session. Their <Terminal> stays
  // mounted (just hidden) when another pod is selected, so the xterm buffer and
  // its output subscription survive switching — the session is "restored".
  const [opened, setOpened] = useState<string[]>([]);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const selectedIdRef = useRef<string | null>(null);
  const workspacesRef = useRef<WorkspaceView[]>([]);

  useEffect(() => {
    selectedIdRef.current = selectedId;
  }, [selectedId]);
  useEffect(() => {
    workspacesRef.current = workspaces;
  }, [workspaces]);

  const select = (id: string) => {
    setSelectedId(id);
    setBadges((b) => ({ ...b, [id]: false }));
  };

  useEffect(() => {
    listWorkspaces().then(setWorkspaces).catch(() => {});
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

  // Keyboard shortcuts: Cmd+1..9 selects the Nth workspace; Cmd+B toggles the
  // sidebar. Capture phase + stopPropagation so a focused terminal doesn't also
  // receive the keystroke.
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
        const ws = workspacesRef.current;
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
  // transient "Unknown"/"Pending" status blip, which would needlessly tear down
  // a live session and lose its buffer.
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

  // Pods with a live terminal: those opened (and not since Stopped/removed),
  // plus the selected one eagerly if it's Running, so there's no blank frame on
  // first open.
  const runningTerminals = Array.from(
    new Set([...opened, ...(selected?.state === "Running" ? [selected.id] : [])])
  ).filter((id) => {
    const w = workspaces.find((x) => x.id === id);
    return w !== undefined && w.state !== "Stopped";
  });

  const selectedHasTerminal = !!selected && runningTerminals.includes(selected.id);

  return (
    <div className="app">
      {sidebarOpen && (
        <Sidebar
          workspaces={workspaces}
          selectedId={selectedId}
          badges={badges}
          onSelect={select}
          onStart={(id) => startWorkspace(id).catch(() => {})}
          onStop={(id) => stopWorkspace(id).catch(() => {})}
        />
      )}
      <main className="main">
        {!selected && <div className="empty">Select a workspace</div>}
        {selected && !selectedHasTerminal && (
          <ActionPanel
            workspace={selected}
            onDelete={(id) => deleteWorkspace(id).catch(() => {})}
          />
        )}
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
