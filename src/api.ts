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

export const connectPty = (id: string) => invoke<void>("connect_pty", { id });
export const writePty = (id: string, data: number[]) => invoke<void>("write_pty", { id, data });
export const resizePty = (id: string, rows: number, cols: number) =>
  invoke<void>("resize_pty", { id, rows, cols });
export const disconnectPty = (id: string) => invoke<void>("disconnect_pty", { id });

export const onPtyOutput = (
  id: string,
  cb: (bytes: number[]) => void
): Promise<UnlistenFn> => listen<number[]>(`pty-output:${id}`, (e) => cb(e.payload));
