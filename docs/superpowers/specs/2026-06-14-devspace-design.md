# DevSpace — Design Spec

**Date:** 2026-06-14
**Status:** Approved

## Goal

A Tauri desktop application that lists the developer's DevPod workspaces with live
status, lets them start / stop / delete / SSH into workspaces, embeds an interactive
terminal for running workspaces, and surfaces Claude Code notifications originating
inside a workspace as native desktop notifications.

Conceptually similar to Solo (soloterm.com) — a workspace/session dashboard — but as a
GUI app, with DevPod as the workspace backend and Claude Code as the primary in-pod tool.

## Tech Stack

- **Backend:** Rust, Tauri 2.
- **Frontend:** React + TypeScript + Vite (Tauri webview).
- **Terminal:** `xterm.js` (frontend) ↔ `portable-pty` crate (backend) over Tauri IPC.
- **Notifications:** `tauri-plugin-notification`.
- **Workspace backend:** the `devpod` CLI (v0.6.15+), invoked as a subprocess.

## DevPod CLI surface (verified)

- `devpod list --output json` → JSON array of workspaces (id, uid, provider, ide, source,
  creationTimestamp, lastUsed, context). **Fast. No live state.**
- `devpod status <id> --output json [--timeout 10s]` → `{id, context, provider, state}`
  where `state` ∈ {`Running`, `Stopped`, `Busy`, `NotFound`, ...}. **Slow (default 30s
  timeout), per-workspace.**
- `devpod up <id>` → start a workspace.
- `devpod stop <id>` → stop a workspace.
- `devpod delete <id>` → delete a workspace.
- `devpod ssh <id>` → interactive SSH session. Supports:
  - `--command "<cmd>"` — run a one-shot command in the workspace.
  - `-R/--reverse-forward-ports` — reverse port forwarding (pod → desktop).
  - `--set-env KEY=VAL` — set environment variables in the workspace session.

## Architecture

```
┌─ React frontend (webview) ──────────────────────────┐
│  Sidebar: workspace list, status dot, start/stop/del │
│  Main:   <Terminal/> (xterm.js)  |  <ActionPanel/>   │
└───────────── Tauri IPC (commands + events) ──────────┘
┌─ Rust backend ───────────────────────────────────────┐
│  devpod.rs  → shells `devpod list/status/up/stop/...` │
│  poller.rs  → throttled background status refresh      │
│  pty.rs     → portable-pty runs `devpod ssh <id> -R…` │
│  hooks.rs   → inject Claude hook via ssh --command     │
│  notify.rs  → local HTTP listener ← reverse tunnel     │
└───────────────────────────────────────────────────────┘
        │ devpod CLI               ▲ reverse SSH tunnel
        ▼                          │
   DevPod workspaces ── Claude Code hook curls localhost:8765
```

## Components

### Backend (`src-tauri/src/`)

**`devpod.rs`** — typed wrapper over the CLI.
- Shells out through an injectable `CommandRunner` trait so logic is unit-testable with a
  fake runner (no real `devpod` in CI).
- `list() -> Vec<Workspace>` — parse `devpod list --output json`.
- `status(id) -> WorkspaceStatus` — parse `devpod status <id> --output json --timeout 10s`.
- `up(id)`, `stop(id)`, `delete(id)` — fire actions, surface stderr on failure.
- One Rust struct per JSON shape; tolerant of unknown fields.

**`poller.rs`** — background status refresh.
- Every ~10s runs `list()` to refresh the workspace set + metadata.
- Refreshes `status()` per workspace concurrently with a semaphore cap of 4 and a short
  per-call timeout; caches last-known state.
- Emits a `workspaces-updated` Tauri event with the merged list+status snapshot.
- Re-polls a single workspace immediately after a start/stop/delete action.
- Never crashes on CLI error; records a per-workspace error state instead.

**`pty.rs`** — terminal session registry, keyed by workspace id.
- On first selection of a Running workspace, spawns in a PTY:
  `devpod ssh <id> -R 8765:localhost:<listener_port> --set-env DEVSPACE_POD_ID=<id> --set-env DEVSPACE_NOTIFY_PORT=8765`
- Pumps PTY output → frontend via `pty-output` event; frontend input → PTY via `pty_write`
  command. Handles resize via `pty_resize`.
- Sessions **persist in background** when the user switches workspaces; switching just
  shows/hides the corresponding xterm buffer. A session is torn down only on app exit,
  workspace stop, or explicit disconnect.
- On session death, marks the workspace terminal "disconnected" (frontend shows Reconnect).

**`hooks.rs`** — Claude Code notification hook injection.
- On first connect to a workspace, idempotently writes a **user-level** hook into the
  pod's `~/.claude/settings.json` via `devpod ssh <id> --command`.
- The hook fires on `Notification`, `Stop`, and `PreToolUse:AskUserQuestion`. It reads the
  event JSON Claude Code provides on stdin and `curl`s
  `http://localhost:$DEVSPACE_NOTIFY_PORT/notify` including `$DEVSPACE_POD_ID` and the
  event type.
- Injected at user level so it applies to every repo in the pod and coexists with (does
  not replace) any existing repo-level `.claude/settings.json` hooks — Claude Code merges
  hooks from all sources and runs every match.

**`notify.rs`** — local HTTP listener for notification callbacks.
- Binds a fixed local port at startup (the reverse-tunnel target). On bind failure, the app
  still runs; notifications are disabled with a one-time warning.
- `POST /notify` body carries `{ pod_id, event }`. Maps event → message:
  - `Notification` / `PreToolUse:AskUserQuestion` → "Claude needs your input"
  - `Stop` → "Claude finished"
- Raises a native desktop notification (click → focus window + select that pod) and emits a
  `pod-badge` event so the sidebar shows an unread badge.

**`state.rs` / `main.rs`** — shared `AppState` (workspace cache, session registry, listener
port), Tauri command registration, plugin setup (`tauri-plugin-notification`).

### Frontend (`src/`)

**`Sidebar.tsx`** — one row per workspace: name, provider, status dot, action buttons,
unread badge. Status dot colors:
- green = Running, grey = Stopped, amber = Busy/transitioning, red = error.

**`Terminal.tsx`** — xterm.js bound to a single pod's PTY session. One instance per
connected pod; mounted hidden when its pod is not the active selection (preserves buffer).

**`ActionPanel.tsx`** — shown when a Stopped workspace is selected: Start / Delete buttons
plus metadata (source repo, last used, provider).

**`api.ts`** — thin wrappers over Tauri `invoke` commands and event subscriptions.

## Data flow

1. **Status:** `poller.rs` polls `devpod` → emits `workspaces-updated` → Sidebar re-renders
   status dots. Actions optimistically show a transitioning state, then reconcile on the
   next poll of that pod.
2. **Terminal:** select Running pod → backend ensures a PTY session (spawns `devpod ssh -R…`
   on first open) → bidirectional byte stream over IPC ↔ xterm.js.
3. **Notifications:** Claude Code hook (inside pod) → `curl` reverse tunnel → `notify.rs`
   listener → native notification + sidebar badge → click focuses window and selects pod.

## Notification routing details

- Transport is independent of where the hook is defined; the reverse tunnel carries traffic
  for both user-level and repo-level hooks.
- Each pod's reverse forward maps pod `localhost:8765` → desktop listener. Multiple pods
  share the desktop port; the backend disambiguates by `pod_id` in the payload (set via
  `--set-env DEVSPACE_POD_ID`).
- **Lazy tunnel (chosen tradeoff):** the tunnel rides on the terminal PTY's SSH connection,
  created on first open of the pod and persisted in background. A pod the user has never
  opened has no session/tunnel and therefore will not notify.

## Error handling

- CLI failure (non-zero exit / malformed JSON / timeout) → workspace row shows an error
  state with stderr in a tooltip; poller keeps running.
- SSH session dies → terminal shows "disconnected" + Reconnect button.
- `notify.rs` bind failure → app runs, notifications disabled, one-time warning surfaced.

## Testing

- **Rust:** unit tests for `devpod.rs` JSON parsing against captured real fixtures; the
  `CommandRunner` trait is faked so no real `devpod` is needed in CI. `notify.rs` tested by
  POSTing to the listener and asserting the emitted event/notification payload.
- **Frontend:** Vitest component tests for Sidebar status rendering and action dispatch.

## Scope

**In (v1):** list workspaces, live status, start / stop / delete, embedded SSH terminal,
Claude Code notification routing, persistent background sessions.

**Out (later):** creating new workspaces from scratch, multi-context UI, build/logs viewers,
in-app Claude launching, settings UI for poll interval / ports.
