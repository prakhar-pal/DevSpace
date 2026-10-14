# Remaining DevSpace Linux Port — Milestone Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan milestone by milestone in the current checkout and main thread. Do not create worktrees or delegate implementation. Inspect the macOS implementation before each milestone; ask questions only where genuine ambiguity remains.

## Direction

Use the macOS implementation as the reference for workflows, availability of actions, dialogs and session behavior. Implement Linux presentation in Swift with native GTK4 and VTE.

Reuse existing backend features rather than rebuild them. Keep libghostty rendering parity and Ubuntu 24.04 validation deferred. Each milestone produces a usable increment and a small conventional commit.

## M01 — Workspace actions and sidebar organization

Port macOS sidebar behavior:

- Friendly-name dialog; Move Up/Down with boundary disabling.
- Hide/Show and collapsible Hidden section, retaining access to the selected hidden workspace.
- Context menus with Disconnect, Reload SSH Session, New Terminal and Open in Zed, enabled according to workspace/session state.
- Restore macOS-inspired hover actions and New/Guide access using GTK controls—not a persistent toolbar.
- Keep names, status dots and selection highlighting; preserve natural sidebar sizing.

Reuse existing `alias`, `hide`, `show`, ordering and collapse commands plus the current layout format.

**Acceptance:** aliases never change DevPod IDs; organization survives restart; selected/background terminals survive sidebar updates; unavailable actions cannot run.

## M02 — Workspace creation and lifecycle UI

Port the macOS creation, recreation and status-panel flows:

- Create dialog with repository URL and optional DevPod ID.
- Start/Stop actions, connection progress and actionable connection failures.
- Recreate confirmation with the same destructive-operation warning.
- Live provisioning/start/stop/recreate output, cancellation and retained failure output.
- Select the discovered workspace after successful creation; reconnect only after lifecycle completion and confirmed running status.

Reuse existing operation commands and snapshots. Do not add a Delete UI merely because the backend supports deletion—the current macOS UI is the reference.

**Acceptance:** duplicate submission is blocked; cancellation affects only its operation; failures remain readable; SSH cleanup precedes destructive operations; stopped workspaces never start merely through selection.

## M03 — Multiple terminal tabs

Match macOS terminal behavior:

- Explicit New Terminal creates another shell sharing the workspace’s existing SSH master.
- Selection and polling never create additional terminals.
- Show a numbered tab strip, close controls and “+” only when multiple tabs exist.
- Preserve background shells, scrollback and the active tab per workspace.
- Closing one tab preserves siblings; closing the last disconnects without stopping the DevPod.
- Reload waits for the previous master to exit before creating the replacement session.

Add an explicit private `new_terminal` command; keep `connect` idempotent. Track stable pane order and active pane identity in the GTK adapter. Retain generation-bound lifecycle events.

**Acceptance:** two independent shell round-trips over one master; correct focus after switching/closing; no duplicates after repeated snapshots; stale events cannot close or inject into replacements.

## M04 — Keyboard, terminal navigation and Guide

Translate macOS application shortcuts into Linux-safe bindings:

- Ctrl+Shift+C/V: copy and text/image paste.
- Ctrl+Shift+R/T/O/B: reload, new terminal, Zed and sidebar toggle.
- Ctrl+Shift+1–9: select visible workspace.
- Ctrl+PageUp/PageDown: previous/next terminal tab.
- Ctrl+Shift+Alt+Up/Down: reorder selected workspace.

Suppress workspace shortcuts while dialogs own input. Leave ordinary terminal Ctrl keys untouched. Port current-directory reporting through VTE’s directory-URI signal for tab titles and editor targets.

Provide a GTK Guide containing the actual supported actions and bindings.

**Acceptance:** modal input remains usable; shortcuts target the active workspace/pane; terminal Ctrl+C/Ctrl+R still reach the shell; Unicode paths produce correct titles and targets.

## M05 — Editor and notification workflow parity

Finish differences around integrations already implemented:

- Open in Zed targets the active terminal’s directory, with macOS-equivalent workspace fallback.
- Explicit `ded` paths must never fall back to opening a different folder.
- Preserve macOS stale-request protection and editor-launch fallback rules using Linux executable discovery.
- Verify notification badges, clearing on selection and activation of the existing workspace terminal.
- Verify automatic hook installation and disconnect cleanup, preserving unrelated settings and hooks needed by another live DevSpace channel.

Do not rebuild notification transport, hooks or image upload.

**Acceptance:** missing/failing Zed remains nonfatal; authenticated notifications activate the original pane without opening another; reconnect/disconnect races cannot install stale hooks or remove a peer’s working integration.

## M06 — Host acceptance and regression closure

Exercise the completed workflows on the current Ubuntu desktop:

- Wayland and X11: input, resize, focus, scrollback, selection, text/bracketed paste and theme changes.
- Actual clipboard-image upload and cleanup.
- Real notification-banner activation and available input-method behavior.
- Shutdown/relaunch, failed SSH recovery, and development/production coexistence.
- Authorized running `wc-1`: multiple shells, reload, notification hooks and disconnect without stopping the workspace.

Use fixtures for creation/start/stop/recreate unless a disposable workspace is explicitly authorized. Record manual checks separately from automated evidence.

**Acceptance:** every workflow above has direct evidence or an explicitly recorded platform limitation; macOS regression checks remain green.

## M07 — Production package and handoff

- Finish and verify the `.deb` with confirmed GPL-3.0-or-later icons, runtime notices and approved Git maintainer identity.
- Verify package dependencies, desktop entry, launcher, relocation and absence of repository-local toolchain requirements.
- Install and run on a clean Ubuntu 26.04 environment without development tools; exercise the installed application against an authorized DevPod.
- Update documentation and PR #111 through the established stack workflow.
- Build production artifacts only with release approval; never replace or stop the running production app without separate permission.

**Acceptance:** installable package, successful installed-app workflow, current Linux/macOS CI, and an evidence-backed completion checklist.

## Testing and execution rules

- Swift XCTest for portable logic; native Swift GTK/VTE tests for UI/session behavior; existing packaging harnesses for artifacts.
- Run affected tests per milestone. Run broader suites for shared lifecycle/protocol changes and once for final release verification—not after every documentation change.
- Inspect the relevant macOS implementation and dependencies before each milestone.
- Work in the current feature checkout, in the main thread; commit independently verified increments.
- No renderer replacement, speculative settings surface, split panes or automatic network-reconnection feature beyond current macOS behavior.
