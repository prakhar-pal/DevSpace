# dev-space

## v0.6.1 - 2026-07-25

### Fixes
- fix: TerminalPane quit libghostty (716d6a0)

### Other
- chore: update readme (1ccbee6)
- chore: update readme (d9b9a77)


## v0.6.0 - 2026-07-23

### Features
- feat: paste images into the terminal (⌘V copies to the pod over SSH) (547dea8)

### Fixes
- fix: prevent libghostty's own paste from also inserting the filename (23605c7)
- fix: read the real file bytes when an image FILE is pasted, not its icon (38aaa69)


## v0.5.5 - 2026-07-13

### Fixes
- fix: never wake stopped devpods — sessions only for intended pods (566dd3e)

### Other
- build: move the debug log out of the TCC-gated Documents folder (15d5675)


## v0.5.4 - 2026-07-10

### Fixes
- fix: hold debounced revivals as absent (Loading), not fabricated Stopped (f8a2998)
- fix: ⌘O focuses the selected pod's Zed window, not the last-used one (04e7159)
- fix: debounce k8s' false Running-after-stop status flips; poll every 10s (09d6597)

### Other
- build: give dev builds their own bundle id (com.prakharp.devspace.dev) (eea585e)
- build: rename the dev build to DevSpaceDev and fix the title-bar name (b93825a)
- chore: remove the legacy Tauri/React tree (4e5740e)


## v0.5.3 - 2026-07-09

### Fixes
- fix: make macOS dictation insert text into the embedded terminal (4fbcf53)

### Other
- chore: never kill the production app during development (0b42d16)


## v0.5.2 - 2026-07-07

### Fixes
- fix: don't open duplicate Zed windows for the same devpod folder (1c86ecf)

### Other
- docs: rewrite README for the native Swift app (4bd0abe)


## v0.5.1 - 2026-07-07

### Fixes
- fix: defer workspace-started notification until SSH into the pod succeeds (c707b18)

### Other
- build: add `make install` target for the release app (1d14de0)


## v0.5.0 - 2026-07-04

### Features
- feat(terminal): title tabs with the shell's working directory (43b5714)
- feat(shortcuts): add Cmd+Shift+[ / Cmd+Shift+] to switch terminal tabs (a28e1cc)
- feat(terminal): support multiple terminal tabs per devpod workspace (dca3be9)
- feat(shortcuts): add Cmd+O to open the selected workspace's folder in Zed (852380b)
- feat(notify): notify on devpod start/stop and switch workspace on notification click (7016a3b)
- feat(window): show workspace sequence number and name in the window title (b030e6c)
- feat(shortcuts): add Cmd+R to reload the selected workspace's SSH session (0b05b59)

### Fixes
- fix(terminal): macOS-native tab close button (cef4935)
- fix(notify,zed): address stack review findings (dff34b2)
- fix(terminal): tabs share the strip width equally (60ebd83)
- fix(terminal): show the tab strip only when more than one tab is open (2d55ab1)
- fix(sidebar): add explicit Move Up/Down workspace reordering (fd5ed40)
- fix(zed): open the workspace folder remotely instead of devpod up --ide zed (e179381)

### Other
- ci(release): fix release-PR lookup to consider only open PRs (346a60a)
- chore: bundle version calculation (3773e47)


## v0.4.0 - 2026-07-02

### Features
- feat(action-panel): show "Last used" in the local timezone (d01b03e)

### Fixes
- fix: handle text pasting inside claude-code (c75a650)
- fix(terminal): focus the selected terminal via first-responder, not @FocusState (ac4ede0)

### Other
- ci: skip build in release PR (d26b7f3)


## 0.3.4

### Patch Changes

- 8d3b60e: fix: introduce delay in hooks::inject to prevent concurrent workspace lock conflicts
- ba88343: fix: Shift+Enter inserts a newline in the terminal instead of submitting
- be18062: fix: write the diagnostic log to .tmp/devspace.log in debug builds only; disable logging in release
- dc3bc7d: chore: remove unused stop wrapper and its unit test

## 0.3.3

### Patch Changes

- 58ee8e3: fix: reload connection failure and headlessly hanging GUI launches
  - **1. GUI Launch PATH Fixes** (`src-tauri/src/path_env.rs`):
    - **Interactive Shell Hang Fix**: Changed the login shell invocation flags from interactive (`-ilc`) to non-interactive (`-lc`). This prevents the application startup from hanging on custom terminal prompts/themes (e.g. Oh My Zsh) when spawned headlessly by macOS LaunchServices.
    - **Robust Path Fallbacks**: Added standard installation paths (`/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin`) directly to the repaired `PATH` environment variable as a fallback, ensuring `devpod` is discoverable.
  - **2. Session Registry & Security Hardening** (`src-tauri/src/pty.rs` & `src-tauri/src/lib.rs`):
    - **Pointer-Based Session Identification**: Created a new method `close_only_if_matches` in the backend `SessionRegistry` that compares raw memory pointers (`Arc::ptr_eq`) of active PTY sessions.
    - **Reload Race Condition Resolution**: Modified the reader thread exit callback to carry a clone of the specific `Session` Arc. The callback will now only remove the session and emit the `pty-closed` event to the frontend if the closing session matches the currently active registry session. This prevents the asynchronous teardown of an old session from killing a newly connected reload session.
    - **TERM Input Sanitization**: Added a `get_sanitized_term()` helper that sanitizes the user's `TERM` environment variable (allowing only alphanumeric characters, dashes, and underscores) to mitigate SSH argument injection risks.
  - **3. Frontend Terminal State & Reconnect Logic**:
    - **`src/Terminal.tsx`**: Added `setDisconnected(false)` to the terminal initialization block to ensure stale disconnect screens are cleared immediately when the reload action runs.
    - **`src/App.tsx`**: Removed the `reloadingRef` state and its fragile 1-second timeout checks in `reload()` and `onExited` functions. Since the backend pointer check prevents explicitly closed PTY sessions from firing stale close events to new components, these frontend timeout workarounds are no longer necessary.
  - **4. Test Selector Fixes** (`src/Sidebar.tsx`):
    - Added the `ws-row` class name back onto both visible and hidden row containers in the workspace sidebar. This fixes the Vitest querying selection selectors (`closest(".ws-row")`) and allows the frontend test suite to pass cleanly.

## 0.3.2

### Patch Changes

- 1780af4: fix: sidebar menu text size and showing pending state of devpod commands
- 6298e00: fix: SSH auto-reconnect and workspace loading UI improvements

      - feat: detect SSH connection drops and pass exit status to frontend
      - feat: add "Disconnected" UI overlay with manual reconnect button
      - feat: auto-reconnect SSH terminal when OS regains internet connection
      - fix: set SSH ServerAliveInterval to drop hung connections reliably
      - refactor: rename "Pending" workspace state to "Loading"
      - feat: add animated loading spinners to Loading workspaces in sidebar and action

  panel - fix: render Loading state pill with neutral grey instead of red error color - fix: hide "Start" button while workspace status is Loading - style: reduce font size of sidebar dropdown menu items to 13px - revert: remove experimental scroll-wheel terminal rendering hacks - docs: update CLAUDE.md to require .tmp/ for scratchpad scripts

## 0.3.1

### Patch Changes

- 111ccec: - Re-added the "Open in Zed" button to the workspace context menu and updated it to use standard Tailwind utility classes.
  - Added a `sync-version.js` script to automatically synchronize `package.json` versions into `Cargo.toml` and `tauri.conf.json`.
  - Chained the sync script to the `version-packages` command so Changesets will keep the Tauri desktop bundle versions synced automatically during release PR generation.
  - Manually bumped all version files to `0.3.0` to reflect the latest changes in the "About" menu.

## 0.3.0

### Minor Changes

- f024711: added 'open in zed' ide option per workspace in the sidebar context menu
