# DevSpace

A native macOS app for managing [DevPod](https://devpod.sh) workspaces — a live
status sidebar, one-click start/stop/delete, and an embedded terminal
([libghostty](https://github.com/ghostty-org/ghostty)) that SSHes straight into
each workspace. Claude Code notifications from inside a pod are routed back to
macOS over a reverse SSH tunnel, so you know when an agent finishes or needs
input without watching the terminal.

Built with Swift / SwiftUI. Rewritten from a Tauri 2 (Rust + React) app — see
[ADR 0001](docs/adr/0001-rewrite-devspace-native-swift-libghostty.md); the
legacy tree lives in git history.

## Features

- **Workspace sidebar** — live status dots (polled via the `devpod` CLI),
  drag-free reorder (context menu / ⌘⌥↑↓), friendly-name aliases, hide/show
  with a collapsible Hidden section.
- **Embedded terminal** — libghostty surface (GPU-rendered, truecolor,
  ligatures) over `ssh <id>.devpod`; multiple tabs per workspace (⌘T), tab
  titles follow the shell's working directory (OSC 7).
- **Lifecycle** — start (`devpod up` with live log), stop, delete, reload the
  SSH session in place (⌘R); exiting the last shell disconnects and shows the
  status card (Connect/Stop) — the workspace keeps running, and DevSpace never
  wakes a stopped workspace on its own.
- **Open in Zed** (⌘O) — instant `zed ssh://<id>.devpod/<workdir>` remote open.
- **Paste screenshots directly into the terminal** (⌘V) — copied to the pod
  automatically over the existing SSH alias, with a path reference inserted
  for Claude Code to read.
- **Notifications** — workspace started/stopped events (started fires only
  once the app has actually SSH'd into the workspace), plus Claude Code
  finished/needs-input events posted from inside the pod through a reverse
  tunnel; clicking a banner jumps to that workspace.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘1–9 | Select the Nth visible workspace |
| ⌘B | Toggle sidebar |
| ⌘R | Reload the SSH session |
| ⌘T | New terminal tab |
| ⌘⇧[ / ⌘⇧] | Previous / next terminal tab |
| ⌘O | Open workspace folder in Zed |
| ⌘V | Paste image from clipboard (copies to pod, inserts path) |
| ⌘⌥↑ / ⌘⌥↓ | Move workspace up / down in the sidebar |

The in-app **Guide** (sidebar footer) lists everything.

## Deprecated features
The native Swift rewrite intentionally retires these behaviors from the
previous Tauri version:

- **Automatic SSH reconnection** — if a terminal disconnects because the
  network or remote workspace becomes unavailable, DevSpace leaves the
  workspace running and shows its status card. Reconnect manually with
  **Connect**; automatic retry when connectivity returns is not implemented.
- **Reliable drag-to-reorder** — SwiftUI's macOS `List` reordering conflicts
  with the sidebar row's selection and controls. Use **Move Up / Move Down** in
  the workspace context menu or **⌘⌥↑ / ⌘⌥↓** instead.

## Requirements

- macOS 14+ (Apple Silicon or Intel)
- Xcode's Swift toolchain (`swift` on PATH) — building uses pure SwiftPM, no
  `xcodebuild` or `.xcodeproj`
- The [`devpod` CLI](https://devpod.sh/docs/getting-started/install) configured
  with your provider
- Optional: [Zed](https://zed.dev) for ⌘O, a
  [Ghostty](https://ghostty.org) config at `~/.config/ghostty/config` (the
  embedded terminal adopts its font/theme/colors)

## Build & install

```bash
make build-dev   # DEV build: "DevSpaceDev.app" (amber icon, logging on)
make run         # build-dev + launch
make test        # unit tests (swift test)
make build       # RELEASE build: "DevSpace.app"
make install     # release build + install to $APP_INSTALL_LOCATION (default /Applications)
make clean       # remove build output
```

`make install` honors an exported `APP_INSTALL_LOCATION` or a command-line
override (`make install APP_INSTALL_LOCATION=~/Apps`), and refuses to replace a
running instance.

Launch via LaunchServices — notification permissions depend on it:

```bash
open "build/DevSpaceDev.app"
```

Notes:

- The first build downloads libghostty's prebuilt xcframework from GitHub
  releases (network required once; cached afterwards).
- Bundles are ad-hoc signed. On another Mac, Gatekeeper requires right-click →
  Open; distributable builds need Developer ID signing + notarization.

## How notifications work

The app listens on `127.0.0.1:17865` (token-gated `POST /notify`). Each
workspace's primary SSH session carries `-R 8765:localhost:17865`, and on
connect both builds inject Claude Code hooks into the pod. DevSpaceDev also
installs a `~/.devspace-notify` manual-test helper. Claude Code events inside
the pod then post through the tunnel and surface as macOS banners (with a
dock-bounce + sidebar-badge fallback). To test from an open DevSpaceDev
workspace terminal, run `~/.devspace-notify`.

## Development

- `Sources/App/` — SwiftUI UI and the `AppModel` state machine.
- `Sources/Core/` — portable, UI-free logic (devpod CLI, poller, PTY, SSH,
  notify listener, hook injection, layout persistence) with unit tests in
  `Tests/Core/`.
- `Sources/CPTY/` — C shim for `forkpty`.
- Debug builds log to `.tmp/devspace.log` (a symlink to
  `~/Library/Logs/DevSpaceDev.log` — outside the TCC-protected Documents
  folder); release builds write no log.
- Sidebar layout persists at
  `~/Library/Application Support/DevSpace/layout.json`.

Releases are automated with shell scripts (no Node): merging conventional
commits to `main` refreshes a `chore: release vX.Y.Z` PR
(`scripts/next-version.sh` + `scripts/prepare-release.sh`); merging that PR
tags the version. CI skips build/test on release PRs.
