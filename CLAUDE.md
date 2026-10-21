# DevSpace

Native macOS (Swift / SwiftUI) desktop app to manage DevPod workspaces: live
status sidebar, start/stop/delete, an embedded `ssh <id>.devpod` terminal
(libghostty), and Claude Code notification routing over a reverse SSH tunnel.

Rewritten from the original Tauri 2 (Rust) + React/TypeScript app — see
`docs/adr/0001-rewrite-devspace-native-swift-libghostty.md`. The Swift project
lives at the repo root; the legacy Tauri/React tree was removed (it remains in
git history before this commit).

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
make build-dev   # DEV build: assembles "DevSpaceDev.app" (amber icon, logging on)
make build       # RELEASE build: assembles "DevSpace.app"
make test        # unit tests (swift test)
make run         # build-dev then launch the app
make install     # release build + install to $APP_INSTALL_LOCATION (default /Applications)
make clean       # remove build output
```

On Linux, `make install` builds and installs the Swift/GTK/VTE production
bundle under `~/.local` (no sudo, no .deb). Override `LINUX_INSTALL_PREFIX`
for an isolated verification prefix, or pass `LINUX_INSTALL_BUNDLE` to install
an existing production bundle without rebuilding. The installer refuses a
running destination and unrelated files; never install over the user's daily
driver without approval. See `docs/linux-development.md`. Use temporary
prefixes under `.tmp` for installer tests, not the user's actual installation.

**During development always use `make build-dev` / `make run`** (the amber
"DevSpaceDev" build with logging to `.tmp/devspace.log`). Use `make build`
(release "DevSpace") only for producing a distributable bundle.

**Always confirm with the user before running `make build` (release) or before
killing/quitting a running release bundle (`DevSpace.app`)** — even when
diagnosing a release-only failure. Dev builds (`make build-dev` / `make run`)
and dev instances need no confirmation.

**Never close the production app during development.** The installed release
bundle (`DevSpace.app` at its install location) is the user's daily driver and
must keep running while dev builds are tested alongside it. Both bundles
share the executable name `DevSpace`, so `pkill -x DevSpace` kills BOTH —
always match dev instances by bundle path:
`pkill -f "build/DevSpaceDev.app"`.

Dev vs prod are fully distinct to macOS: `scripts/assemble-app.sh` sets
`CFBundleDisplayName` ("DevSpaceDev" vs "DevSpace"), the icon
(`DevSpaceDev.icns` vs `DevSpace.icns`), and the bundle id
(`com.prakharp.devspace.dev` vs `com.prakharp.devspace`) per build
configuration — separate ids keep LaunchServices/Notification Center/TCC
identities apart. The Swift module name (`DevSpace`) stays the same.

Built bundles:
- Dev:     `build/DevSpaceDev.app`
- Release: `build/DevSpace.app`

Launch via LaunchServices (not the bare binary — macOS notifications/permissions
depend on it):

```bash
open "build/DevSpaceDev.app"
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

- Runtime log (notify path, PTY lifecycle): `.tmp/devspace.log` — a symlink
  to `~/Library/Logs/DevSpaceDev.log`, kept outside the TCC-gated ~/Documents
  so the ad-hoc dev build never blocks on a consent prompt (debug builds
  only — release builds write no log; controlled by the `DevSpaceLogPath`
  Info.plist key the assembly script sets for Debug).
- Manual notification trigger inside a pod (DevSpaceDev only): open the
  workspace in DevSpaceDev, then run `~/.devspace-notify` in that terminal (it
  uses this session's reverse tunnel). `~/.devspace-notify Notification` sends
  a "needs input" event. Production DevSpace does not install this helper.

## Agent Rules

- **Validate instead of assuming wherever possible.** Before diagnosing,
  changing behavior, or claiming an outcome, inspect the relevant source code
  and trace its dependencies up to two levels deep (direct dependencies and
  their dependencies). Read the relevant project documentation and check it
  against the implementation; resolve discrepancies using evidence rather
  than treating either as automatically authoritative. Inspect the relevant
  tests, run checks appropriate to the change, and confirm their actual output.
  State what was verified, what remains unverified, and any assumptions that
  could not be checked. Do not claim runtime behavior from source inspection
  alone or claim tests pass without running them.
- **Use conventional-commit-style branch names.** Prefix the branch with the
  change type, followed by a concise kebab-case description; for example,
  `feat/dide-zed-folder`, `fix/terminal-shortcut-routing`, or
  `docs/update-contributing-guide`.
- **Agents may commit only on a non-`main`/non-`master` branch.** Never run
  `git commit` or `git push` while checked out on `main` or `master`; create
  and use a feature branch instead.
- **Commit completed milestones incrementally.** On a non-`main`/non-`master`
  feature branch, commit each small, independently verified milestone with a
  conventional commit message. Stage only files belonging to that milestone;
  leave unrelated or unfinished working-tree changes unstaged.
- **Always use `gh stack` to create PRs**, including single-PR changes. When PR
  creation is explicitly authorized, establish local stack tracking with
  `gh stack init` (or extend it with `gh stack add`), then publish with
  `gh stack submit`; do not use `gh pr create`. Never use `gh stack link`
  alone because it creates remote-only metadata that `gh stack submit` cannot
  use from the local branch.
- **Avoid git worktrees.** Work in the current checkout unless an exceptional,
  life-or-death isolation need has been explicitly confirmed by the user.
- **When asked to build a feature or fix a bug while on `main` or `master`,**
  create a feature branch first. Otherwise, work on the current feature branch.
- **Use `.tmp/` for temporary files** (the project-root `.tmp`, which is
  `.gitignore`d). Application logs go to `.tmp/devspace.log` (a symlink to
  `~/Library/Logs/DevSpaceDev.log`; debug builds only).
- **Prefer commands that run inside the sandbox first**, and only bypass if
  blocked by standard sandbox constraints (e.g. the libghostty download).
