# DevSpace — Features

DevSpace is a macOS desktop app (Tauri 2 + React/TypeScript) for managing
[DevPod](https://devpod.sh) workspaces. It gives you a live status sidebar, an
embedded SSH terminal per workspace, and routes Claude Code notifications from
inside your pods back to your desktop over a reverse SSH tunnel.

This document is the user-facing feature reference. For build/run instructions
see [`CLAUDE.md`](CLAUDE.md).

---

## Workspace list & status

- **Live sidebar list** — every DevPod workspace appears in the left sidebar,
  discovered automatically on launch (`src/App.tsx`, `src-tauri/src/poller.rs`).
- **Real-time status** — a background poller refreshes each workspace's status
  every ~3 seconds. A colored dot encodes the state
  (`src/Sidebar.tsx:statusColor`):
  - 🟢 **green** — Running
  - ⚪ **grey** — Stopped (or status still loading)
  - 🟠 **amber** — Busy
  - 🔴 **red** — Unknown / error
  - A spinner replaces the dot while a workspace is starting or its status is
    being fetched.
- **Workspace details panel** — selecting a non-running workspace shows its ID,
  state, provider, source (git repo or folder), and last-used date
  (`src/ActionPanel.tsx`).

## Starting, stopping & deleting

- **Start** — select a stopped workspace and press **Start**. The live
  `devpod up` log streams into the view; when startup finishes the SSH terminal
  opens automatically (`src/ActionPanel.tsx`, `src/StartLog.tsx`).
- **Stop** — hover a running workspace and click the ⬛ stop button, or simply
  type `exit` in its terminal — DevSpace runs `devpod stop` and shows the
  shutdown log until the container is down (`src/Sidebar.tsx`, `src/App.tsx`).
- **Delete** — removes a workspace via `devpod delete`
  (`src-tauri/src/lib.rs`).

## Embedded SSH terminal

- **Auto-connect** — running workspaces are SSH'd into automatically using a
  real PTY (`ssh -tt <id>.devpod`) rendered with xterm.js (`src/Terminal.tsx`,
  `src-tauri/src/pty.rs`).
- **Reconnect on drop** — when the OS reports the network is back, the terminal
  auto-reconnects; a manual reconnect button appears on connection errors.
- **Reload SSH session** — right-click a running workspace → **Reload SSH
  Session** to re-establish the shell without restarting the pod.
- **Copy / paste** — `⌘C` copies the selection, `⌘V` pastes (via the native
  clipboard for reliability in WKWebView). OSC 52 is supported for
  tmux/neovim copy, with clipboard *reads* blocked to prevent exfiltration.
- **Clickable links** — URLs in output open in the default browser with
  `⌘`+click.
- **Editing niceties** — `⇧ Enter` inserts a newline without sending;
  `⌥ ←/→` does word navigation.
- **Background-friendly** — window focus in/out is forwarded to the terminal so
  Claude Code doesn't spin the CPU when the app is unfocused.

## Organizing the sidebar

- **Reorder** — drag workspaces up/down; the order persists across restarts.
- **Rename (friendly names)** — right-click → **Set friendly name…** to give a
  workspace a readable label without changing its real ID
  (`src/RenameModal.tsx`).
- **Hide / show** — right-click → **Hide** moves a workspace into the **Hidden**
  section at the bottom of the sidebar; **Show** restores it. Click the Hidden
  header to collapse/expand the section — the collapsed state is remembered
  across restarts.
- **Open in Zed** — right-click → **Open in Zed** launches the Zed editor inside
  the remote workspace (`devpod up --ide zed`).
- All sidebar state (order, hidden set, aliases) is persisted to
  `layout.json` under `~/Library/Application Support/DevSpace`
  (`src-tauri/src/layout.rs`).

## Claude Code notification routing

- **Automatic hook injection** — when you open a workspace, DevSpace injects
  Claude Code notification hooks into the pod's `~/.claude/settings.json` and
  sets up a reverse SSH tunnel. Injection is idempotent
  (`src-tauri/src/hooks.rs`, `src-tauri/src/lib.rs`).
- **Desktop notifications** — when Claude finishes (Stop) or needs your input
  (Notification / AskUserQuestion), the pod POSTs to the desktop listener and
  you get:
  - a native macOS notification banner, **or**
  - a **dock-icon bounce + blue sidebar dot** fallback when banners are
    suppressed (unsigned app on managed/MDM Macs).
- **Unread badge** — a blue dot on a workspace marks an unread Claude
  notification; selecting the workspace clears it.
- **Manual test** — run `~/.devspace-notify` inside a pod's DevSpace terminal to
  fire a test notification (`~/.devspace-notify Notification` for a
  "needs input" event).
- A stable notification token is generated once and persisted (0600) at
  `~/Library/Application Support/DevSpace/notify-token`.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘1`…`⌘9` | Jump to the Nth **visible** workspace |
| `⌘B` | Toggle the sidebar (more room for the terminal) |
| `⇧ Enter` | Insert a newline in the terminal without sending |
| `⌘C` / `⌘V` | Copy selection / paste |
| `Esc` | Close the in-app guide / rename modal |

## In-app guide

A **Guide** button sits at the bottom of the sidebar (just above the Hidden
section). It opens a modal summarizing how to use DevSpace
(`src/GuideModal.tsx`).

## Security & robustness

- **Workspace ID validation** — IDs are restricted to alphanumerics plus `-`/`_`
  (max 64 chars, must start alphanumeric) to prevent CLI flag/shell injection
  before any subprocess is spawned (`src-tauri/src/devpod.rs`).
- **Concurrency-limited polling** — status calls are capped (max ~4 concurrent,
  10s timeout each) so a large pod list doesn't overload the machine.
- **Corruption-tolerant layout** — a malformed `layout.json` reverts to empty
  rather than crashing.

## Dev vs production builds

DevSpace ships two visually distinct builds (`CLAUDE.md`):

- `npm run tauri:dev` — hot-reloading **debug** build, amber **"DevSpace Dev"**
  icon/name, writes a diagnostic log to `.tmp/devspace.log`.
- `npm run tauri:prod` — optimized **"DevSpace"** release build, no logging.
