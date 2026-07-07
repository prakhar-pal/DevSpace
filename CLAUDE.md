# DevSpace

Native macOS (Swift / SwiftUI) desktop app to manage DevPod workspaces: live
status sidebar, start/stop/delete, an embedded `ssh <id>.devpod` terminal
(libghostty), and Claude Code notification routing over a reverse SSH tunnel.

Rewritten from the original Tauri 2 (Rust) + React/TypeScript app — see
`docs/adr/0001-rewrite-devspace-native-swift-libghostty.md`. The Swift project
lives at the repo root; the legacy Tauri/React tree is retained under `tauri/`
for reference (not built).

- App (`Sources/App/`): SwiftUI UI — `DevSpaceApp`, `ContentView`, `Sidebar`,
  `ActionPanel`, `TerminalPane`, `Modals`, `Notifier`, `AppModel` (the top-level
  state machine).
- Core (`Sources/Core/`): portable logic, UI-free and unit-tested — `Devpod`,
  `Poller`, `PTY`, `SSH`, `Notify`, `Hooks`, `Layout`, `SidebarLayout`,
  `PathEnv`, `Log`.
- CPTY (`Sources/CPTY/`): tiny C shim for `forkpty`/`ioctl` (not callable from
  Swift).
- Terminal engine: **libghostty** via the `libghostty-spm` Swift package
  (`GhosttyKit` + `GhosttyTerminal`). The host owns the PTY (`PTYSession`) and
  feeds libghostty's `InMemoryTerminalSession`.

## Build & run

Builds are pure **SwiftPM** driven by the `Makefile` (no `xcodebuild`/`.xcodeproj`):

```bash
make build-dev   # DEV build: assembles "DevSpace Dev.app" (amber icon, logging on)
make build       # RELEASE build: assembles "DevSpace.app"
make test        # unit tests (swift test)
make run         # build-dev then launch the app
make install     # release build + install to $APP_INSTALL_LOCATION (default /Applications)
make clean       # remove build output
```

**During development always use `make build-dev` / `make run`** (the amber
"DevSpace Dev" build with logging to `.tmp/devspace.log`). Use `make build`
(release "DevSpace") only for producing a distributable bundle.

**Always confirm with the user before running `make build` (release) or before
killing/quitting a running release bundle (`DevSpace.app`)** — even when
diagnosing a release-only failure. Dev builds (`make build-dev` / `make run`)
and dev instances need no confirmation.

Dev vs prod are visually distinct: `scripts/assemble-app.sh` sets
`CFBundleDisplayName` ("DevSpace Dev" vs "DevSpace") and the icon
(`DevSpaceDev.icns` vs `DevSpace.icns`) per build configuration; the bundle id
(`com.prakharp.devspace`) and Swift module name (`DevSpace`) stay the same.

Built bundles:
- Dev:     `build/DevSpace Dev.app`
- Release: `build/DevSpace.app`

Launch via LaunchServices (not the bare binary — macOS notifications/permissions
depend on it):

```bash
open "build/DevSpace Dev.app"
```

## Environment notes

- **`xcodebuild` is unusable here:** Xcode's `CoreSimulator.framework` is missing
  and reinstalling it needs admin. Hence pure `swift build` + a hand-assembled
  `.app` (Ronin-style) via the Makefile — never invoke `xcodebuild`.
- **First build needs network:** the first `swift build` downloads libghostty's
  prebuilt xcframework from GitHub releases (may hit a keychain `status -128`
  when sandboxed — run it in a real terminal once; it's cached afterward).
- **Signing:** ad-hoc signed (`codesign --sign -`), no Developer ID. Gatekeeper
  blocks the app on other Macs (right-click → Open); notification banners are
  unreliable on unsigned/MDM Macs, so DevSpace falls back to a dock-icon bounce
  + sidebar badge. A distributable build needs Developer ID signing + notarization.

## Tests

```bash
make test          # swift test (DevSpaceCore unit + listener integration tests)
```

## Diagnostics

- Runtime log (notify path, PTY lifecycle): `.tmp/devspace.log` (debug builds
  only — release builds write no log; controlled by the `DevSpaceLogPath`
  Info.plist key the assembly script sets for Debug).
- Manual notification trigger inside a pod: open the workspace in DevSpace, then
  run `~/.devspace-notify` in that terminal (it uses this session's reverse
  tunnel). `~/.devspace-notify Notification` sends a "needs input" event.

## Agent Rules

- **Never commit files yourself.** Present the changes and the proposed commit
  message (Conventional Commits) and let the user commit. Do not run
  `git commit`/`git push`.
- **Never make commits on the `main` branch.** Work on a feature branch.
- **Use `.tmp/` for temporary files** (the project-root `.tmp`, which is
  `.gitignore`d). Application logs go to `.tmp/devspace.log` (debug builds only).
- **Prefer commands that run inside the sandbox first**, and only bypass if
  blocked by standard sandbox constraints (e.g. the libghostty download).
