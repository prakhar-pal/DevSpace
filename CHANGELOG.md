# dev-space

## 0.3.3

### Patch Changes

- 58ee8e3: ### 1. GUI Launch PATH Fixes

  • src-tauri/src/path_env.rs :
  • Interactive Shell Hang Fix: Changed the login shell invocation flags from interactive ( -ilc ) to non-interactive ( -lc ). This prevents the
  application startup from hanging on custom terminal prompts/themes (e.g. Oh My Zsh) when spawned headlessly by macOS LaunchServices.
  • Robust Path Fallbacks: Added standard installation paths ( /opt/homebrew/bin , /usr/local/bin , and ~/.local/bin ) directly to the repaired PATH
  environment variable as a fallback, ensuring devpod is discoverable.

  ### 2. Session Registry & Security Hardening

  • src-tauri/src/pty.rs & src-tauri/src/lib.rs :
  • Pointer-Based Session Identification: Created a new method close_only_if_matches in the backend SessionRegistry that compares raw memory
  pointers ( Arc::ptr_eq ) of active PTY sessions.
  • Reload Race Condition Resolution: Modified the reader thread exit callback to carry a clone of the specific Session Arc. The callback will now
  only remove the session and emit the pty-closed event to the frontend if the closing session matches the currently active registry session. This
  prevents the asynchronous teardown of an old session from killing a newly connected reload session.
  • TERM Input Sanitization: Added a get_sanitized_term() helper that sanitizes the user's TERM environment variable (allowing only alphanumeric
  characters, dashes, and underscores) to mitigate SSH argument injection risks.

  ### 3. Frontend Terminal State & Reconnect Logic

  • src/Terminal.tsx :
  • Added setDisconnected(false) to the terminal initialization block to ensure stale disconnect screens are cleared immediately when the reload
  action runs.
  • src/App.tsx :
  • Removed the reloadingRef state and its fragile 1-second timeout checks in reload() and onExited functions. Since the backend pointer check
  prevents explicitly closed PTY sessions from firing stale close events to new components, these frontend timeout workarounds are no longer necessary.

  ### 4. Test Selector Fixes

  • src/Sidebar.tsx :
  • Added the ws-row class name back onto both visible and hidden row containers in the workspace sidebar. This fixes the Vitest querying selection
  selectors ( closest(".ws-row") ) and allows the frontend test suite to pass cleanly.

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
