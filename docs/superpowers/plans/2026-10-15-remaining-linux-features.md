# Remaining DevSpace Linux Port — Prioritized Milestone Plan

> **For agentic workers:** Use superpowers:executing-plans in the current checkout and main thread. Do not create worktrees or delegate implementation. Inspect macOS source before each milestone; ask only where genuine ambiguity remains. These milestone numbers supersede the original ordering. The user subsequently authorized continuing through all remaining milestones; release/installation and real-workspace mutation still require their separate approvals.

## Direction

Use macOS as the reference for feature behavior, action availability, dialogs and session lifecycle. Implement Linux presentation in Swift with native GTK4 and VTE. The user's importance ratings determine delivery order: prioritize DevSpace integration and daily use over conveniences already available through DevPod CLI.

Reuse existing backend features rather than rebuilding them. Keep libghostty rendering parity and Ubuntu 24.04 validation deferred. Deliver usable, independently verified increments with small conventional commits. Later optional features must not block earlier delivery.

## User priorities

### Execution checkpoint — 2026-10-15

M01 implemented and independently reviewed. Start/Stop controls, operation output
and targeted cancellation use the existing backend. Workspace notifications now
reuse macOS state gating/debounce and foreground suppression. Review fixes retain
hook cleanup eligibility after the last shell exits, close its frontend pane,
allow ready-owned-master integration during transient status, and forget readiness
when an ID is removed. Silent VTE map/resize no longer signals readiness.
Verified: Core234 (one opt-in skip), backend38, native GTK7 (one live skip), and
both development executable builds. No production replacement or real lifecycle
mutation occurred. Live wc-1/hook/banner acceptance remains pending: its latest
read-only status was Stopped. Current-head macOS CI has not yet run for this change.

Ruling: external starts follow the macOS confirmed-status exception rather than
waiting forever for SSH the app intentionally does not open. Intended connections
still wait for output after failure. VTE readiness requires visible child content;
silent/whitespace-only shells wait until visible text instead of reporting readiness
from map/resize events. Cost: such custom shells may delay hook installation.
Verification uses existing scratch caches and the plan/Git checkpoint rather than
adding a new execution workspace or repeated full Linux/package suite runs.

M02 implemented: a real private-clipboard race reproduced text paste into a
hidden workspace before the fix. Image-to-text fallback now performs its own
asynchronous text read and rechecks the live/mapped pane at each completion,
then uses VTE paste_text to preserve bracketed mode. Native checks verify Unicode,
multiline text, byte-exact bracketed framing, selection copy, and callbacks after
hide/disposal. GTK7 passed (one live skip); the Swift app product rebuilt.
The physical host clipboard was not read or replaced. M03 is next.

M03 first increment implemented: Ctrl+Shift+1–9/B/O/R route through a native
window key controller without swallowing ordinary terminal Ctrl keys; editable
controls retain their input. VTE OSC 7 reports generation-bound decoded paths,
and validated open_zed requests preserve Unicode/space-containing folders and
reject stopped/unknown/busy workspaces and relative paths. GTK7 (one live skip),
backend39, and both development product builds passed. M03 is NOT complete:
frontend image-size limits, editor discovery/fallback parity and latest live
integration acceptance remain. M04–M10 remain unimplemented.
The goal controller was queried and still reports paused; direct turn work is
authorized, but automatic continuation requires resuming the goal in the UI.

M03 second increment: a real approximately18 MB private clipboard PNG reproduced
oversized frontend staging. The frontend now shares ImageUpload.maximumBytes
(16 MiB) and rejects oversized encoded PNGs before creating files or upload
requests, displaying a nonfatal error without pasting unrelated clipboard text.
GTK7 passed (one live skip), ImageUploadTests2 passed, and development products
rebuilt. Tests clean their generated PNGs, including the failing oversized case.
M03 remains open for editor discovery/fallback parity and live acceptance;
M04–M10 are not implemented. No release build/installation is claimed.

M03 third increment: Linux editor discovery now honors absolute PATH entries
first, then standard user/system Zed install locations. A private-home native
GTK test failed for a user install outside PATH before the fix, then passed;
it also verifies PATH override precedence and exact remote URL delivery without
launching the user's editor. GTK8 passed (one opt-in live skip, including the
backend regression suite); development products and bundle rebuilt. Missing and
nonzero-exit Zed remain nonfatal. Fallback policy/stale-request parity and live
acceptance still remain before M03 completion. Per the latest user instruction,
open the development build after each verified milestone, preserving production.

M03 editor fallback implemented: CLI requests always target the workspace URL;
missing/failing CLI checks for an existing Zed SSH session off the GTK thread.
An existing session uses the registered Zed desktop application, never DevPod
provisioning. Otherwise only a non-explicit keyboard request may use
Devpod.ideArgs; explicit ded folders report a nonfatal error instead of silently
opening another folder. Keyboard OSC 7 inference is now distinguished from ded.
Per-workspace generations reject completions after disconnect, reload, stop,
workspace unavailability and shutdown. GTK11 passed (one opt-in live skip),
including backend39, exact fallback argv, private desktop activation and a
delayed-failure-after-disconnect check. Read-only wc-1 status remains Stopped;
live image/helper/editor acceptance remains pending, not claimed complete.
Ruling: Linux uses GIO's registered dev.zed.Zed.desktop activation as the native
counterpart to NSWorkspace activation. Cost: a desktop entry that does not
honor single-instance activation may behave differently; no DevPod provisioning
is attempted when an existing remote session is detected.

M04 implemented: running disconnected workspaces expose Connect/retry, owned
connection phases distinguish connecting/disconnecting from idle, and existing
terminal rows offer Disconnect/Reload SSH Session in a right-click menu without
persistent extra sidebar buttons. Busy workspaces reject Connect/Reload.
An explicit Connect during Disconnect is retained until hook cleanup and the old
master's exit; reload still waits for lease release and rejects old callbacks.
Verified: Core235 (one opt-in skip), GTK11 (one live skip, including backend40),
both development products, and the busy-workspace protocol case directly.
No real workspace lifecycle commands were run. Native menu ownership survives
polling and backend failure; disconnect/terminal exit remain SSH-only actions.

Latest user UI adjustment implemented in this increment: establish the sidebar
minimum once at twice its original content-sized width, rather than doubling on
each poll. Native regression reproduced an unset minimum with a 172 px fixture
baseline before the change and now verifies the doubled floor plus terminal
expansion. A later longer name can grow the sidebar without ratcheting its floor.
M05–M10 remain; M03 live wc-1 acceptance is still pending (Stopped on recheck).

### Ratings

Pxx identifiers are stable and separate from historical Fxx identifiers. P06's final rating of 9 supersedes its earlier rating of 8.

| ID | Feature | Importance / 10 | Milestone |
| --- | --- | --- | --- |
| P01 | Start/stop DevPods | 10 | M01 |
| P02 | Workspace lifecycle notifications | 10 | M01 |
| P03 | Connect/disconnect/reload SSH and recovery | 7 | M04; readiness prerequisite in M01 |
| P04 | Automatic Claude hook installation/cleanup | 10 | M01 |
| P05 | Claude notifications, badges and activation | 10 | M01 |
| P06 | Terminal text copy/paste | 9 | M02 |
| P07 | Clipboard-image upload | 8 | M03 |
| P08 | Open in Zed / authenticated ded | 8 | M03 |
| P09 | Keyboard navigation and session shortcuts | 8 | M03 |
| P10 | Friendly workspace names | 5 | M06 |
| P11 | Saved sidebar ordering | 5 | M06 |
| P12 | Hide/show workspaces | 2 | M08 |
| P13 | Multiple terminal tabs | 1 | M09 |
| P14 | Create workspaces | 1 | M10 |
| P15 | Recreate workspaces | 1 | M10 |
| P16 | In-app Guide | 1 | M10 |
| P17 | UI/input polish | 6 | M05 |
| P18 | Production .deb | 3 | M07 |

## M01 — Start/stop and DevSpace notification lifecycle

**Features:** P01, P02, P04, P05 — all 10/10.

- Add state-appropriate Start/Stop actions, busy-state disabling, operation progress and retained errors using existing commands/snapshots. Keep compact rows; do not add provisioning dialogs or tabs.
- Match macOS lifecycle notifications: distinguish confirmed Running/Stopped transitions from initial discovery and unknown/transient status. Announce becoming usable only after the owned SSH connection produces its first terminal output, not merely when Start returns.
- Detect externally initiated stops, including provider inactivity shutdown, through polling without issuing lifecycle commands. Repeated snapshots must not repeat notifications. Match macOS foreground/selected-workspace suppression and badge behavior.
- Match macOS's external-start exception: a workspace restarted outside DevSpace, with no intended app connection, announces its confirmed Running transition without opening SSH. Intended app connections still require first output, including after a failed connection awaiting explicit retry.
- Finish/verify automatic Claude hooks once per live connection and safe removal on disconnect. Preserve unrelated settings and another live channel's integration. Hook success remains implicit; failures are nonfatal and actionable.
- Finish/verify Claude finished/needs-input alerts, badges, clearing on selection and click-to-focus of the existing terminal.

Readiness and generation-safe cleanup are prerequisites here; fix defects blocking notifications/hooks, but defer additional SSH controls and recovery presentation to M04. Reuse macOS transition gating rather than inventing another notification policy.

**Acceptance:** fixture-controlled start/stop and external transitions produce the correct single event; initial/unknown states produce no false alerts; first output gates the live event; selection never starts a stopped workspace; stale integration completions cannot alter replacements; notification activation creates no duplicate terminal.

## M02 — Reliable terminal text copy/paste

**Feature:** P06 — 9/10.

- Verify and finish selection, Ctrl+Shift+C/V, ordinary text paste and bracketed paste through the active VTE terminal.
- Preserve terminal Ctrl+C/Ctrl+R and dialog text input.
- Preserve selection/scrollback across workspace switches and polling. Stale clipboard callbacks cannot target hidden or retired panes.

**Acceptance:** actual private-display clipboard round-trips, multiline/Unicode text and bracketed paste; ordinary Ctrl keys reach the shell; missing text and closed-pane callbacks fail safely. Record physical-host clipboard acceptance separately; replacing the user's physical clipboard requires authorization.

## M03 — Image paste, editor integration and keyboard navigation

**Features:** P07, P08, P09 — all 8/10.

- Finish/verify image upload into the original active pane, bounded PNG handling, local/remote temporary-file cleanup and nonfatal failures. Reuse the existing transport.
- Open in Zed targets the active terminal directory with macOS-equivalent workspace fallback. Explicit ded paths never fall back to another folder. Preserve stale-request protection and editor fallback rules with Linux executable discovery.
- Port VTE directory-URI reporting for editor targeting; tab-title presentation remains deferred to M09.
- Add Ctrl+Shift+R/O/B for reload, Zed and sidebar toggle; Ctrl+Shift+1–9 selects visible workspaces. Retain copy/paste from M02 and suppress workspace shortcuts during dialogs.

Do not add new-tab, tab-navigation or reorder shortcuts before their owning milestones. Reuse reconnect for the reload shortcut before expanding recovery UI in M04.

**Acceptance:** exact uploaded bytes and correct injection target; stale upload cannot inject into a replacement; Unicode/space-containing editor paths are correct; missing/failing Zed stays nonfatal; shortcuts do not swallow ordinary shell keys.

## M04 — Explicit SSH controls and recovery

**Feature:** P03 — 7/10; builds on M01 readiness guarantees.

- Expose Connect, Disconnect and Reload SSH Session according to macOS state/session eligibility.
- Show progress, actionable failures and explicit retry without starting stopped workspaces or adding automatic network reconnection beyond macOS.
- Keep connect idempotent: polling, selection and notification activation reuse the existing terminal.
- Reload waits for the previous master and owned cleanup before replacement. Disconnect/terminal exit never stops the DevPod.
- Verify backend failure leaves the UI responsive and shutdown releases owned resources without touching another instance.

**Acceptance:** retry, reload ordering, late callbacks, repeated connection requests and orderly shutdown; no duplicate panes, unintended DevPod start/stop or interference with production.

## M05 — Native UI and input polish

**Feature:** P17 — 6/10.

- Verify compact sizing, theme changes, scrolling, terminal expansion, focus and readable empty/error/busy states for delivered workflows.
- Exercise Wayland and X11, available input methods, resize, scrollback and mouse selection. Fix observed defects; do not build a Ghostty-like settings surface.
- Verify development/production coexistence and shutdown/relaunch. Separate programmatic evidence from physical desktop checks.

**Acceptance:** high-priority workflows work on the current Ubuntu desktop; theme/selection changes preserve terminal state; direct evidence covers input/focus/layout or explicitly documents platform limitations.

## M06 — Friendly names and saved ordering

**Features:** P10, P11 — both 5/10.

- Add the macOS-inspired friendly-name dialog and Move Up/Down context-menu actions with boundary disabling.
- Reuse existing alias/order commands and persistence; names never change DevPod IDs.
- Add Ctrl+Shift+Alt+Up/Down for reordering the selected visible workspace.

**Acceptance:** names/order survive restart; unavailable actions cannot run; organization and polling preserve selected/background terminals.

## M07 — Production package and high-priority handoff

**Feature:** P18 — 3/10. This release does not depend on M08–M10.

- Build/verify the .deb with confirmed GPL-3.0-or-later icons, runtime notices and approved Git maintainer identity.
- Verify dependencies, desktop entry, launcher, relocation and absence of repository-local toolchain requirements.
- Install/run on clean Ubuntu 26.04 without development tools and exercise installed M01–M06 workflows against an authorized DevPod.
- Run final Linux/macOS regressions, update docs and PR #111 through the stack workflow, and retain an evidence-backed checklist.
- Build production artifacts only with release approval; never install over, replace or stop production without separate permission.

**Acceptance:** installable package, verified installed-app daily workflow and current Linux/macOS CI. Low-priority conveniences do not block handoff.

## M08 — Optional hide/show organization

**Feature:** P12 — 2/10.

- Add Hide/Show and collapsible Hidden section using existing commands/layout storage.
- Match macOS selected-hidden-row behavior so active workspaces remain reachable. Hiding is not stopping or disconnecting.

**Acceptance:** persistence, collapse/expand and selected-hidden access; no lost terminal state or accidental lifecycle commands.

## M09 — Optional multiple terminal tabs

**Feature:** P13 — 1/10; not required for core usability.

- Add explicit private new_terminal command while keeping connect idempotent. Additional shells share one owned master.
- Show numbered tabs, close controls and + only for multiple panes. Preserve stable order and active-pane identity per workspace.
- Closing a tab preserves siblings; closing the last disconnects without stopping the DevPod. Background shells and scrollback survive switching/polling.
- Add Ctrl+Shift+T and Ctrl+PageUp/PageDown for creation/navigation; use M03 directory reporting for titles.

**Acceptance:** independent shell round-trips over one master, correct focus after switching/closing, stable snapshots and stale-event rejection.

## M10 — Optional provisioning conveniences and Guide

**Features:** P14, P15, P16 — all 1/10. DevPod CLI remains the alternative until this milestone.

- Add Create with repository URL/optional ID and Recreate with the macOS destructive-operation confirmation.
- Reuse backend commands for live provisioning output, cancellation, retained failure output and successful created-workspace selection.
- Reconnect only after lifecycle completion and confirmed running status. Do not add Delete UI merely because the backend supports it; current macOS UI is the reference.
- Add New/Guide access and GTK Guide covering only implemented workflows and actual bindings.

**Acceptance:** duplicate submission blocked, cancellation scoped to its operation, readable failures, SSH cleanup before recreation, no stopped workspace awakened by selection, and Guide matching shipped behavior.

## Testing and execution rules

- Swift XCTest for portable logic; native Swift GTK/VTE tests for UI/session behavior; existing packaging harnesses for artifacts. Use TDD for behavior changes.
- Run affected tests per milestone. Run broader suites for shared lifecycle/protocol changes and once for release verification—not after every documentation change.
- Validate host-facing acceptance within its owning milestone; do not postpone everything until packaging. Distinguish fixture-only and manual evidence.
- Inspect macOS source and dependencies up to depth two before changes. macOS semantics outrank earlier UI preferences; ratings determine scheduling, not replacement behavior.
- Use fixtures for create/start/stop/recreate unless a disposable real workspace is explicitly authorized. Existing wc-1 authorization covers temporary SSH/hook tests, not lifecycle mutation or project-file edits. Recheck availability before live tests.
- Preserve production and unrelated edits. Use global Swift, keep scratch evidence in .tmp, restore Package.resolved after Linux Swift commands and commit verified milestones on the feature branch.
- No renderer replacement, speculative settings surface, splits or automatic network-reconnection feature beyond macOS.
