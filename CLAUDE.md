# DevSpace

Tauri 2 (Rust) + React/TypeScript desktop app to manage DevPod workspaces: live
status sidebar, start/stop/delete, an embedded `ssh <id>.devpod` terminal
(xterm.js), and Claude Code notification routing over a reverse SSH tunnel.

- Backend: `src-tauri/src/` (`devpod`, `poller`, `notify`, `hooks`, `pty`, `lib`).
- Frontend: `src/` (`App`, `Sidebar`, `ActionPanel`, `Terminal`, `api`).

## Build & run

```bash
npm install                 # first time
npm run tauri:dev           # DEV build: hot-reload + amber "DevSpace Dev" icon/name
npm run tauri dev           # dev runtime with the production icon (no override)
npm run tauri build         # PRODUCTION build: optimized .app + .dmg ("DevSpace")
```

Dev vs prod are visually distinct: `tauri:dev` merges `src-tauri/tauri.dev.conf.json`,
which uses the amber icon set in `src-tauri/icons-dev/` and the product name
"DevSpace Dev". Production uses `src-tauri/icons/` and "DevSpace".

Production artifacts (release, arm64):
- App:  `src-tauri/target/release/bundle/macos/DevSpace.app`
- DMG:  `src-tauri/target/release/bundle/dmg/DevSpace_<version>_aarch64.dmg`

Run a built bundle (launch via LaunchServices, not the bare binary — macOS
notifications/permissions depend on it):

```bash
open src-tauri/target/release/bundle/macos/DevSpace.app
```

## Tests

```bash
npm test                                  # frontend (Vitest)
cd src-tauri && cargo test                # backend (Rust)
```

## Environment notes

- **cargo not on PATH:** if `cargo`/`rustc` aren't found (broken rustup shim),
  prefix commands with the toolchain bin, e.g.:
  ```bash
  PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH" npm run tauri build
  ```
- **Do not regenerate `src-tauri/Cargo.lock`:** it pins `alloc-no-stdlib = 2.0.4`
  to work around an upstream brotli/alloc-no-stdlib incompatibility. Adding deps
  is fine; deleting/regenerating the lockfile reintroduces the build break.
- **Signing:** builds are ad-hoc signed (no Developer ID). Gatekeeper will block
  the app on other Macs (right-click → Open), and notification banners are
  unreliable for an unsigned app on managed/MDM Macs — DevSpace falls back to a
  dock-icon bounce + sidebar badge. A distributable build needs Developer ID
  signing + notarization.

## Diagnostics

- Runtime log (notification path, PTY lifecycle): `~/Library/Logs/DevSpace/devspace.log`.
- Manual notification trigger inside a pod: open the workspace in DevSpace, then
  run `~/.devspace-notify` in that terminal (it uses this session's reverse
  tunnel). `~/.devspace-notify Notification` sends a "needs input" event.
