# dev-space

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
