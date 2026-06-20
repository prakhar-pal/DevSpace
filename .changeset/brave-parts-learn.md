---
"dev-space": patch
---

- Re-added the "Open in Zed" button to the workspace context menu and updated it to use standard Tailwind utility classes.
- Added a `sync-version.js` script to automatically synchronize `package.json` versions into `Cargo.toml` and `tauri.conf.json`.
- Chained the sync script to the `version-packages` command so Changesets will keep the Tauri desktop bundle versions synced automatically during release PR generation.
- Manually bumped all version files to `0.3.0` to reflect the latest changes in the "About" menu.
