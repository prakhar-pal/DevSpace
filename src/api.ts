import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export interface WorkspaceView {
  id: string;
  provider: string;
  source: string;
  last_used: string;
  state: string;
  error: string | null;
}

export const listWorkspaces = () => invoke<WorkspaceView[]>("list_workspaces");
export const startWorkspace = (id: string) => invoke<void>("start_workspace", { id });
export const stopWorkspace = (id: string) => invoke<void>("stop_workspace", { id });
export const deleteWorkspace = (id: string) => invoke<void>("delete_workspace", { id });

export const onWorkspacesUpdated = (
  cb: (views: WorkspaceView[]) => void
): Promise<UnlistenFn> => listen<WorkspaceView[]>("workspaces-updated", (e) => cb(e.payload));

export const onPodBadge = (cb: (podId: string) => void): Promise<UnlistenFn> =>
  listen<string>("pod-badge", (e) => cb(e.payload));
