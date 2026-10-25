# dev-space

## v0.9.0 - 2026-10-25

### Features
- feat(linux): make libghostty wrapper the default renderer (79ca87a)
- feat(linux): expose native accessible terminal text and caret (ea28828)
- feat(linux): integrate experimental Ghostty GTK terminal (5428ad7)
- feat(linux): add portable Swift Skia terminal renderer (3e6898b)
- feat(linux): add portable Swift Ghostty terminal engine (fa97fa0)
- feat(linux): support safe user-local make install (3a8cb1d)
- feat(linux): route terminal clipboard through Swift-owned PTY (6f9fe26)
- feat(core): decode bounded terminal clipboard writes (0ce0130)
- feat(linux): add provisioning dialogs and native workflow guide (9eaee71)
- feat(linux): add explicit terminal tabs sharing SSH masters (a380747)
- feat(linux): add hidden workspace organization (0eb6521)
- feat(linux): add friendly names and saved workspace ordering (0e93a91)
- feat(linux): scroll workspace lists and expose orderly quit (4c9034c)
- feat(linux): add SSH session controls and wider sidebar minimum (ef596c0)
- feat(linux): preserve editor fallback and stale-request safety (e81d858)
- feat(linux): add workspace shortcuts and directory-aware editor routing (afe6de9)
- feat(linux): add lifecycle controls and workspace notifications (af1c157)
- feat(linux): enable private development diagnostics (2f3e12d)
- feat(linux): auto-connect running DevPods and manage hooks (bc7f1f6)
- feat(linux): add Debian package build pipeline (58720bd)
- feat(linux): route clipboard images through VTE (c10fce3)
- feat(linux): add terminal clipboard and reconnect shortcuts (deba937)
- feat(linux): add Swift GTK and VTE terminal app (37a80a9)
- feat: add Linux GTK UI-first development port (b9eeb07)

### Fixes
- refactor(linux): remove superseded migration build paths (aa6fca2)
- fix(linux): harden experimental Ghostty terminal acceptance (336d48f)
- fix(linux): support production builds and protected process checks (2719d3c)
- fix(linux): set fixed sidebar width (79303ca)
- fix(core): harden PTY cleanup and clipboard validation (ffcb8ec)
- fix(core): drain Linux PTY output before exit callbacks (e4e2043)
- fix(linux): normalize GTK spacing and action hierarchy (a0124a7)
- fix(linux): preserve focused sidebar controls during polling (72c898b)
- fix(linux): expose workspace menus and route native shortcuts (f473b05)
- fix(linux): request unformatted lifecycle progress logs (7cee580)
- fix(linux): retain successful creation through bounded discovery (410251e)
- fix(linux): bound and scroll expanded hidden workspaces (80d7b64)
- fix(linux): defer SSH until provisioning has completed (354bad6)
- fix(linux): hand off the first shell after independent integration (4dc9f0d)
- fix(linux): preserve client failure status and bounded SSH retries (2dee5e9)
- fix(linux): preserve mixed hooks and match installed desktop identity (ae6f3d2)
- fix(linux): guard provisioning requests and retain failed output (bec663b)
- fix(linux): bound SSH recovery and preserve disconnect intent (da79775)
- fix(ssh): fail closed when DevPod proxy resolution fails (313fe93)
- fix(linux): discover user-installed Zed outside desktop PATH (94419d5)
- fix(linux): bound clipboard PNG staging before upload (4e78c81)
- fix(linux): bind asynchronous clipboard paste to visible panes (ad2aead)
- fix(linux): drain SSH diagnostics and clean owned helpers (23e3fa5)
- fix(linux): require and package ICU runtime notices (03c3a9e)
- fix(linux): preserve bundle licenses and checkout package version (c1b00f9)
- fix(linux): avoid epoll read-source teardown for PTY sessions (7841009)
- fix(linux): preserve notification hooks for live peer tunnels (a8287a6)
- fix(linux): reject launches from retired terminal generations (a1d1d68)
- fix(ssh): expire configuration deadline before master readiness (e027d85)
- fix(ci): provide shell prerequisites and handle root permissions (7b7034a)
- fix(linux): size sidebar to workspace names (6e8fa1b)
- fix(linux): match VTE colours to the GTK theme (e3078e4)
- fix(linux): clear recovered SSH errors and remove pane headers (1f461d2)
- fix(linux): use status dots in workspace sidebar (2de65cb)
- fix(linux): install Claude hooks without sidebar status (7af2027)
- fix(linux): show only the selected workspace terminal (7869b8f)
- fix(linux): keep sidebar sizing stable (836dd9c)
- fix(linux): surface asynchronous editor launch failures (fb78442)
- fix(linux): route notification activation and preserve warnings (c6e3920)
- fix(linux): disconnect callbacks before terminal disposal (f92cdd2)
- fix(linux): expand VTE to terminal pane height (e5c1fa1)
- refactor(linux): retire Ghostty Zig frontend prototype (e9bafdc)

### Other
- test(linux): validate accelerated terminal GPU rendering (8d48b22)
- test(linux): verify reconnect editor and image acceptance (07f1be3)
- test(linux): require real input for Wayland clipboard acceptance (b26ade1)
- test(linux): check external desktop clipboard round trips (1f03521)
- test(linux): verify Herdr clipboard and independent Ghostty PTYs (551d0b6)
- build(linux): package and verify experimental Ghostty bundles (dc3eaa0)
- build(linux): preserve explicit native dependency notices (2dff6e7)
- test(linux): verify GTK Unicode composition (3e08a36)
- test(linux): validate Ghostty and Skia runtime integration (dac30d6)
- test(linux): verify direct Swift Skia interoperability (cca4e5c)
- docs(linux): close Herdr and editor runtime acceptance gates (9780fa2)
- test(linux): synchronize stale poll with stop completion (c159075)
- docs(linux): record desktop notification click acceptance (d859550)
- docs(linux): record installed bundle integration acceptance (c152779)
- test(linux): verify cross-terminal DevPod clipboard transfers (090858d)
- docs(linux): record manual cross-app clipboard acceptance (05d23d7)
- docs(linux): define remote clipboard release acceptance paths (523b6fb)
- docs(linux): verify clean Ubuntu runtime startup and shutdown (3e12ed0)
- docs(linux): record clipboard regression and current release gates (2ae7a4f)
- docs(linux): plan approved sidebar and native input fixes (9a2a22e)
- docs(linux): inventory macOS shortcut parity and safe mappings (da4304d)
- docs(linux): specify discoverable sidebar controls and input checks (b0d1f62)
- test(linux): verify live workspace handoff hooks and shared shells (f8f8b70)
- docs(linux): record automated acceptance and release verification (52fdf78)
- docs(linux): record verified final milestone bundle (e9597ab)
- test(linux): verify window-driven terminal resizing (6b806cb)
- docs(linux): describe shipped workflows and approved icon licensing (a5122b2)
- docs(linux): record verified production milestone build (c92b927)
- docs(plan): prioritize DevSpace workflows by user ratings (81f8960)
- docs(plan): outline remaining Linux feature milestones (6cc75ec)
- docs(license): cover custom icons and Linux package copyright (c8947a6)
- test(linux): retire obsolete Ghostty install coverage (8ab145f)
- docs: license DevSpace source under GPL-3.0-or-later (e723860)
- docs(linux): refresh approved UI and completion evidence (26795ee)
- test(linux): verify live forward cancellation and activation focus (c6e8601)
- docs: require evidence-based validation for agent work (3367bf3)
- test(linux): verify host helper and editor routing (89e03a4)
- test(linux): verify host frontend image upload (fb7aa0e)
- test(linux): verify host terminal close and reopen (6bed543)
- docs(linux): record fresh host Wayland acceptance (23efd1a)
- docs(linux): correct debug channel acceptance setup (d29ca36)
- ci(linux): verify Swift GTK builds on Ubuntu 26.04 (097572c)
- test(linux): isolate Xvfb accessibility state (30a1612)
- test(linux): stabilize host VTE acceptance reporting (0fbb3dd)
- docs(linux): record isolated wc-1 VTE acceptance (25aa462)
- docs(linux): record clean global Swift verification (c956f43)
- docs(linux): warn before refreshing active bundle (0460b92)
- docs(linux): guard active dev bundle replacements (c4e1e02)
- docs(linux): align package checklist with VTE design (95fa838)
- docs(linux): update verification audit (46f2359)
- docs(linux): record active workspace test conflict (97afede)
- docs(linux): record wc-1 integration side effect (4cfb974)
- docs(linux): update host acceptance status (6fbdab5)
- test(linux): scope host VTE smoke to shell roundtrip (332f285)
- docs(linux): record bundled app smoke test (5fb0929)
- docs(linux): record private app smoke run (b0105bc)
- docs(linux): clarify current bundle acceptance status (33dc579)
- test(linux): verify real workspace through GTK terminal (27e5053)
- docs(linux): record GTK port completion status (f362a05)
- test(linux): isolate GTK and host integration runs (fab9f9c)
- build(linux): bundle Swift GTK frontend by default (4da690c)
- docs: commit verified milestones incrementally (94bf32d)


## v0.8.0 - 2026-09-30

### Features
- feat: deprecate dide helper (3739ee4)
- feat: recover failed multiplex ssh clients (fff8745)
- feat: recover multiplexed terminal transports (fb5b51c)
- feat: manage multiplexed ssh transports (cf7b5b3)
- feat: add multiplexed ssh arguments (101a302)

### Fixes
- fix: restart ssh master on reload (4ba385c)
- fix: defer reconnect until ssh master exits (36ac19b)
- fix: shorten multiplex ssh control socket path (f3ead97)
- fix: harden multiplexed ssh recovery (b04e4f1)
- fix: isolate multiplexed ssh transport owners (6f0a64e)
- fix: recover disrupted ssh sessions (9b280f0)

### Other
- docs: specify ded helper deprecation (81dc06f)
- docs: plan multiplexed ssh terminals (e2f91f1)
- docs: complete multiplex transport design (e51bc82)
- docs: harden multiplex transport design (b99b347)
- docs: specify multiplexed ssh terminal tabs (2d7d3b8)
- chore: remove content view preview (3b7c323)


## v0.7.1 - 2026-09-04

### Fixes
- fix: separate shell restart from interrupt (c7bccab)
- fix: retain ssh startup state after timeout (afbc72d)
- fix: close final review gaps (062fcdf)
- fix: route pod notifications through a live build (88602f2)
- fix: route dide through an available build (b0d4e5a)
- fix: separate dev and prod tunnel environments (35f5f51)
- fix: guard ssh retries across status changes (48c04a4)
- fix: recover transient ssh connection failures (6406359)

### Other
- docs: plan build-aware pod routing (1ed2c39)
- docs: simplify pod routing design (c9710e8)
- docs: design build-aware pod routing (2b45b1c)
- test: require scheduled ssh retry (46c3f04)
- docs: design resilient ssh connect (1d0205c)


## v0.7.0 - 2026-08-27

### Features
- feat: expose devpod workspace actions (b93021d)
- feat: present devpod lifecycle dialogs and logs (d368014)
- feat: manage create and recreate lifecycle (00720d6)
- feat: build devpod create and recreate requests (12696c6)
- feat: open dide folders in zed (7f95ea2)
- feat: inject dide pod folder helper (bdc6d3e)
- feat: add authenticated dide listener requests (471effa)
- feat: classify app shortcut routes (1df81ea)

### Fixes
- fix: invalidate delayed Zed launches (808793b)
- fix: prevent cancelled PTY startup (a3f2fbc)
- fix: restrict Zed to live devpods (d07f4c0)
- fix: reap cancelled PTY children (24a259b)
- fix: isolate creation callbacks (bd81f7d)
- fix: expose creation cancellation (3777c7b)
- fix: cancel active devpod creation (4474332)
- fix: order devpod lifecycle polling (420aa70)
- fix: guard devpod lifecycle interactions (515074e)
- fix: isolate dev reverse tunnel ports (1f89d6f)
- fix: harden dide shell helper (5881ac7)
- fix: document dide listener and utf8 validation (9c311f5)
- fix: avoid clipboard reads while modal is open (9ee3a85)
- fix: guard terminal shortcut ownership (2e11ac6)
- fix: route app shortcuts through terminal (f9f2852)
- fix: show devpod lifecycle logs (65cfeb7)

### Other
- docs: remove milestone scan reference (5570a55)
- docs: plan lifecycle review fixes (b7ba32e)
- docs: remove lifecycle milestone label (06cb2e4)
- docs: tighten devpod lifecycle guards (8407b91)
- test: cover cancelled creation refresh (6242da9)
- docs: record cancellation review fixes (98c1469)
- docs: plan devpod creation cancellation (179340c)
- docs: preserve terminal escape input (83a9489)
- docs: make devpod creation dismissible (659e3a7)
- docs: plan devpod lifecycle (fce4e8a)
- docs: define devpod lifecycle (a50d4dc)
- docs: record DIDE review correction (14f33b6)
- docs: plan dide zed folder launcher (a096575)
- docs: require conventional branch names (4adb013)
- docs: design dide zed folder launcher (05c82ae)
- test: verify terminal monitor handoff (b4f5132)
- docs: refine terminal shortcut routing plan (41caac4)
- docs: strengthen shortcut routing design (99acb16)
- docs: design terminal shortcut routing (742101f)


## v0.6.4 - 2026-08-18

### Fixes
- fix: harden DevPod SSH helper invocations (4509d51)
- fix: reject stale SSH proxy resolutions (4d88b84)
- fix: resolve DevPod proxy before terminal launch (a3dc32c)
- fix: reject shell expansion in DevPod proxy (42f84c9)
- fix: disable DevPod services for app SSH (b6f4098)

### Other
- docs: verify DevPod SSH collision fix (dc8e02c)
- test: cover proxy parameter expansion rejection (3ad5475)
- docs: plan DevPod SSH collision fix (0a4bfdf)
- docs: preserve DevPod SSH alias behavior (f0fc497)
- docs: design DevPod SSH collision fix (06b33cb)


## v0.6.3 - 2026-08-17

### Features
- feat: add adversarial code review skill (c5a8993)

### Fixes
- fix(connect): parallelize shell integration handoff (dccc99b)
- fix: close notify helper release gaps (6e8c38a)
- fix: limit manual notify helper to dev builds (416e7cc)
- fix: intercept Cmd+B before libghostty key handling (454f65d)

### Other
- test(connect): cover late integration timeout (3d62d5f)
- test: verify settings preservation during hook injection (96cb542)
- docs: codify branch and worktree rules (1b1ab2b)
- docs: require gh-stack for pull requests (685aacb)


## v0.6.2 - 2026-08-15

### Fixes
- fix: consume Cmd+B before terminal input (94925f3)
- fix: initialize terminal directory tracking (baaa33a)
- fix: open Zed at active terminal directory (294c9f6)

### Other
- docs: add Zed current-directory design (ec7a766)


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
