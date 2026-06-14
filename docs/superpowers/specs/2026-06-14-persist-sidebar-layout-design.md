# Persist Sidebar Layout — Design Spec

**Date:** 2026-06-14
**Status:** Approved

## Goal

Make the sidebar's workspace **order** (drag-reordered) and **hidden set** survive
app restarts reliably, by moving their persistence from the WebView's
`localStorage` to a Rust-owned JSON file in the app config directory.

## Problem

Order and hidden are currently persisted in `localStorage` (`devspace.order`,
`devspace.hidden`). In the bundled macOS app this does not reliably survive a
restart (WebKit local-storage persistence is opaque and environment-dependent),
so the user's custom order resets. A backend file removes that dependency.

## Approach

Persist a single `Layout { order, hidden }` to
`~/Library/Application Support/DevSpace/layout.json`, read and written by the
Rust backend and exposed to the frontend through two Tauri commands. The
frontend loads it on mount and saves on change, replacing `localStorage`.

Rejected alternative: keep `localStorage` and debug WebKit persistence — opaque,
varies by environment, harder to inspect than a plain JSON file.

## Components

### Backend — `src-tauri/src/layout.rs`

```rust
#[derive(Default, Serialize, Deserialize)]
pub struct Layout {
    #[serde(default)]
    pub order: Vec<String>,
    #[serde(default)]
    pub hidden: Vec<String>,
}
```

- `pub fn parse(json: &str) -> Layout` — tolerant parse; invalid/garbage → `Layout::default()`.
- `pub fn serialize(layout: &Layout) -> String` — to JSON.
- `pub fn path() -> Option<PathBuf>` — `~/Library/Application Support/DevSpace/layout.json` (via `$HOME`).
- `pub fn load() -> Layout` — read file → `parse`; missing/unreadable → default.
- `pub fn save(layout: &Layout)` — `create_dir_all` the config dir, then write
  the JSON. Best-effort: failures are swallowed (the layout is a non-critical
  preference). The directory is the same one used for the notify token.

### Tauri commands — `src-tauri/src/lib.rs`

- `#[tauri::command] fn load_layout() -> layout::Layout` — returns `layout::load()`.
- `#[tauri::command] fn save_layout(order: Vec<String>, hidden: Vec<String>)` —
  calls `layout::save(&Layout { order, hidden })`.
- Both registered in `generate_handler!`. `mod layout;` added.

### Frontend — `src/api.ts`

```ts
export interface Layout { order: string[]; hidden: string[]; }
export const loadLayout = () => invoke<Layout>("load_layout");
export const saveLayout = (order: string[], hidden: string[]) =>
  invoke<void>("save_layout", { order, hidden });
```

### Frontend — `src/App.tsx`

- Remove the `ORDER_KEY`/`HIDDEN_KEY` `localStorage` constants, `loadIds`, the
  `useState(() => loadIds(...))` initializers, and the two save effects.
- Initialize `order`/`hidden` to `[]`.
- On mount (the existing subscription effect), call `loadLayout()` and seed
  `setOrder`/`setHidden` from the result.
- Add one effect that calls `saveLayout(order, hidden)` whenever `order` or
  `hidden` changes (fire-and-forget, `.catch(() => {})`). Guard the very first
  run so we don't immediately overwrite the file with empty arrays before
  `loadLayout` resolves (e.g., skip saving until the initial load has applied).

## Data flow

1. Mount → `load_layout` → `order`/`hidden` seeded.
2. The existing normalize effect appends newly-appeared workspaces and drops
   removed ones (unchanged behavior).
3. User reorders / hides / unhides → `order`/`hidden` state changes → the save
   effect writes `layout.json`.
4. Next launch → step 1 restores the saved order/hidden.

## Error handling

- Missing or corrupt `layout.json` → `Layout::default()` (empty order → falls
  back to devpod list order; empty hidden → nothing hidden).
- Write failure → swallowed (best-effort; a lost preference write is non-fatal).
- No `$HOME` → `path()` returns `None`; load returns default, save is a no-op.

## Ordering / first-save race

`loadLayout` is async. The save effect must not fire with empty arrays before
the load resolves, or it would clobber the saved file. Gate saving behind a
"loaded" flag (a ref set true once `loadLayout` resolves and seeds state); the
save effect returns early until then.

## Testing

- Rust unit tests in `layout.rs`:
  - `parse` round-trips a serialized `Layout`.
  - `parse` of malformed JSON returns `Layout::default()`.
  - `parse` of `{}` (missing fields) returns empty vecs (serde defaults).
- Frontend: existing Vitest suite still passes; wiring verified by `npm run build`.

## Scope / non-goals

- **In:** persist order + hidden to a backend JSON file; remove `localStorage`.
- **Out:** migrating existing `localStorage` values (order re-establishes once);
  window geometry; open/selected-workspace session restore.
