import { useEffect, useState } from "react";
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

  useEffect(() => {
    listWorkspaces().then(setWorkspaces).catch(() => {});
    const subs = [
      onWorkspacesUpdated(setWorkspaces),
      onPodBadge((podId) =>
        setBadges((b) => (podId === selectedId ? b : { ...b, [podId]: true }))
      ),
    ];
    return () => {
      subs.forEach((p) => p.then((un) => un()));
    };
  }, [selectedId]);

  const selected = workspaces.find((w) => w.id === selectedId) ?? null;

  const select = (id: string) => {
    setSelectedId(id);
    setBadges((b) => ({ ...b, [id]: false }));
  };

  return (
    <div className="app">
      <Sidebar
        workspaces={workspaces}
        selectedId={selectedId}
        badges={badges}
        onSelect={select}
      />
      <main className="main">
        {!selected && <div className="empty">Select a workspace</div>}
        {selected && selected.state === "Running" && (
          <>
            <div className="term-header">
              <span>{selected.id}</span>
              <button onClick={() => stopWorkspace(selected.id).catch(() => {})}>Stop</button>
            </div>
            <Terminal key={selected.id} podId={selected.id} />
          </>
        )}
        {selected && selected.state !== "Running" && (
          <ActionPanel
            workspace={selected}
            onStart={(id) => startWorkspace(id).catch(() => {})}
            onDelete={(id) => deleteWorkspace(id).catch(() => {})}
          />
        )}
      </main>
    </div>
  );
}
