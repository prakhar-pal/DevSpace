# Swift GTK/VTE Linux UI Design

Status: user-directed on 2026-10-13. This supersedes the earlier Ghostty
adapter design for Linux; it does not change the macOS libghostty application.

2026-10-14 user amendments: list all DevPods and automatically connect running
ones, installing Claude notification hooks on connection and removing managed
notification hooks on disconnect. Keep connections in the background while
showing only the selected workspace's terminal. The sidebar uses selectable,
highlighted rows with green/grey status dots and sizes to workspace names.
Remove sidebar action buttons, the Workspaces heading, terminal title/Close
bars and routine hook-install success messages. VTE follows the GTK theme.
Backend workspace operations remain available; restoring their UI controls is
outside this narrowed UI scope.

## Intent

Build a simple, native GTK Linux interface that is usable quickly. Use Swift for
DevSpace application logic and UI wherever practical. GTK4 and VTE are native C
libraries imported directly into Swift through SwiftPM system-library targets;
do not add a second UI implementation in Zig or Rust. Keep the existing Swift
backend and private protocol as a separate process, and let VTE own terminal
rendering, input, scrollback and its PTY. Linux feature parity with libghostty
is explicitly deferred.

This is DevSpace's workspace manager UI, not a Ghostty UI replica. GTK owns the
application, window, sidebar, workspace actions and empty/error states. The
terminal is an embedded VTE widget. The macOS app continues using SwiftUI and
libghostty unchanged.

## Architecture

- `DevSpaceLinuxApp` is a Swift executable. It imports GTK4/VTE via thin
  Clang module maps and implements app activation, window/layout, workspace
  presentation, and terminal lifecycle in Swift.
- `DevSpaceLinuxBackend` remains the existing Swift executable. It owns
  DevPod operations, polling, workspace/SSH master lifetimes, Claude hooks,
  notifications, image upload and authenticated tunnel behavior. The existing
  versioned private protocol remains the UI/backend boundary.
- A Swift `VteTerminal` wrapper creates a VTE widget only for a validated
  backend terminal-launch effect, passes the approved SSH executable and
  argument array, forwards terminal lifecycle metadata to the existing
  generation-bound protocol, and releases the widget/process on close.
- GTK/VTE are called from Swift directly. A C shim is allowed only for a
  concrete C-interop limitation demonstrated by a failing compile/test; no Zig
  runtime or app code is part of the shipped Linux frontend.
- macOS SwiftUI/libghostty build and behavior are unchanged. Ubuntu 24.04
  validation remains deferred by user direction.

## Scope and ownership

The first GTK window shows a DevSpace-owned workspace sidebar and one terminal
area. It begins empty; it must not launch a local shell. Current NOW actions
remain available through the existing backend. Tabs/splits, advanced terminal
parity, and a Ghostty-like settings surface are not added by this work.

Swift `DevSpaceCore` and `DevSpaceLinuxBackend` retain workspace state,
operations, polling, SSH master ownership, hooks, notification routing, upload,
and pane/generation identities. Swift GTK code owns widgets and maps validated
backend effects to VTE instances. VTE owns terminal parsing/rendering/input and
the terminal child PTY. Terminal bytes never enter the backend control pipe.
No GTK or VTE object is exposed to `DevSpaceCore`.

Keep the existing authorization and safety invariants: no workspace lifecycle
mutation in tests without approval; no physical clipboard replacement;
reject stale pane/generation callbacks; do not stop workspaces when a terminal
widget closes; do not fall back to an unrelated SSH connection; preserve
private dev/prod channel identity, hook authentication, upload limits and
undelivered-image cleanup.

## Alternatives considered

1. Swift GTK4 + VTE via C interop — selected. It keeps application code in the
   requested language and uses the native GTK terminal widget rather than
   rebuilding terminal rendering/input.
2. Zig GTK shell + VTE — rejected as the normal app path because it duplicates
   UI/backend orchestration in another language despite GTK/VTE already having
   C APIs callable from Swift.
3. GTK shell plus Ghostty's Linux internals — deferred. It requires a custom
   renderer/runtime adapter and does not serve the user's immediate priority of
   a quickly usable native Linux terminal.

## Acceptance criteria

- The Linux application entry, UI, backend, protocol handling, and terminal
  lifecycle glue are Swift; GTK4/VTE are linked native C dependencies. Any
  non-Swift shipped code has a specific interop justification.
- A clean launch shows one DevSpace-owned window and a compact workspace list,
  with no local shell. Running workspaces connect automatically and only the
  selected workspace's terminal is visible.
- Opening a running workspace creates one VTE terminal using the backend's
  validated SSH launch effect. Input/output, resize, focus, scrollback, basic
  clipboard paste and terminal close work on the host Ubuntu desktop.
- Backend snapshots do not recreate terminals; stale effects cannot inject
  text into a replacement pane; closing a terminal does not stop its workspace.
- Existing backend, hooks, notification, channel identity, packaging and
  recovery checks remain valid. The old Ghostty/Zig UI is not used by the
  default Linux build after migration.
- macOS tests/build inputs remain unchanged. Ubuntu 24.04 and later Linux
  Ghostty feature parity remain explicit follow-up gates.
