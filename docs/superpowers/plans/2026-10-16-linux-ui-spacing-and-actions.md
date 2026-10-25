# Linux UI spacing and action hierarchy

> **For agentic workers:** Use superpowers:executing-plans in the main thread. Steps use checkbox syntax for tracking.

**Goal:** Polish the existing Swift/GTK C-interop UI without changing workflows or adopting another UI library.

**Approved design:** Consistent padding and control gaps; content-sized actions; primary Start/Connect/Retry and affirmative form actions; neutral secondary actions; destructive Recreate confirmation; selection distinct from primary actions. The user approved proceeding with GTK C interop on 2026-10-16.

**Architecture:** Modify the existing WorkspaceWindow construction paths using GTK margins, alignment, state flags and semantic CSS classes. Keep VTE and backend behavior unchanged. Use the macOS ActionPanel and Modals for action hierarchy, not literal platform styling.

**Tech stack:** Swift, GTK4, VTE, existing native Swift GTK runners.

## Constraints

- Preserve the existing double-content sidebar minimum-width rule.
- Preserve native keyboard focus, shortcuts, disabled states and menu targeting.
- No production rebuild, production termination, new dependency or backend change.
- Temporary captures/logs belong in `.tmp`; commit verified milestones on the current feature branch.

## Tasks

- [x] Add native Swift rendered-layout regression checks in `Tests/LinuxApp/WorkspaceWindowTests.swift`, registered through the existing Python runner. Reproduce stretched lifecycle buttons and touching row controls before changing production code.
- [x] Fix spacing in `Sources/LinuxApp/WorkspaceWindow.swift`: 16px sidebar insets, 8px control gaps, 24px action-panel insets on every edge, 20px modal content insets. Keep action buttons content-sized, including failure/retry and operation panels. Give popover items flat menu styling with internal padding. Inspect mapped-window captures, including long aliases and operation output, rather than relying only on layout property assertions.
- [x] Run affected layout, sidebar, scrolling and lifecycle tests. Commit together with hierarchy below: the rendered-dialog test exposed action-edge spacing and the shared test file now also covers the action roles.
- [x] Add failing native Swift checks for action hierarchy. Set `suggested-action` only on Start/Connect/Retry/Create/friendly-name confirmation. Retain `destructive-action` for Recreate only; secondary controls remain neutral. Render selected rows/tabs with native checked-state styling, not `suggested-action`, and verify selection survives reactivation/polling.
- [x] Run hierarchy, provisioning, tab, native-key and sidebar-focus regressions; commit the combined verified UI milestone.
- [x] Run the Linux test suite, build the development bundle, inspect the rendered UI and reopen DevSpaceDev. Record results and limitations here; leave production files unchanged.

## Review focus

Check narrow windows/long aliases, hidden workspaces, wrapped operation/errors, disabled primary actions, and keyboard input after restyling. Native theme determines colours and focus indicators; do not hardcode a palette. VTE roots must remain unpadded after retry recovery.

## Evidence

- Baseline `spacing` native Swift test failed because Start filled the panel. A captured baseline independently showed touching row controls.
- First spacing patch: 5 affected layout/lifecycle/sidebar/scrolling checks passed (42.792s).
- Extended dialog/role tests then failed for missing bottom/right action-area padding and missing Start primary styling. Visual inspection also exposed centered form labels; the extended role test failed for repository-label alignment before that fix.
- First full affected GTK/controller module: 26 tests, 2 skips, one failure in the nested backend suite (`test_retry_checks_fresh_status_before_attempting_ssh`, connection still `connecting`). All UI checks passed. A fresh final Linux run will establish the final result; no backend code changed.
- Captures in `.tmp/ui-spacing-after` show native primary Start/Create/Retry, red destructive Recreate, neutral secondary controls, and distinct selection. Inspected final Create/Rename/Recreate, stopped/running, retry, and narrow error/operation captures; retry recovery also verifies that VTE's root remains unpadded.
- Execution follows the approved main-thread workflow; progress stays in this plan and git rather than adding another scratch ledger/worktree. Source base: `72c898b78b33162d7c31a730b2b9ac9711bd2712`.
- First complete Linux run passed: 116 tests, 5 opt-in skips, 254.591s. Both direct and nested backend retry suites passed on that run. Further narrow-window coverage was added afterward.
- Independent read-only review found no verified defects; it requested completing narrow/wrapped-text captures and recording final results. Real remote SSH, production packaging and macOS remain outside this UI change; other native themes and physical Wayland input are not claimed tested.
- The additional 680×420 failure-to-operation transition reproduced a fatal `gtk_widget_is_ancestor` assertion. File-backed subprocess output exposed the crash that initially appeared as a timeout; the Swift runtime's abort/backtrace delayed exit. Retain file-backed output for these two new test modes, also avoiding inherited portal-pipe EOF waits.
- Stack investigation traced GTK's selectable-label focus path: [GTK 4.22.4 gtklabel.c](https://github.com/GNOME/gtk/blob/4.22.4/gtk/gtklabel.c#L1611) stores the previous focus widget before transferring focus, then inspects it. The app's shared `clear` removed focused children without explicitly releasing focus first. The fix clears focus only when it belongs to the subtree being replaced; terminal/sidebar focus elsewhere remains untouched. The existing narrow transition is the failing regression; focused keyboard/sidebar checks and a fresh full suite are required after this change.
- Focus fix GREEN: 5 affected native layout/action/lifecycle/keyboard/sidebar tests passed (58.489s), including 680×420 wrapped errors and long scrolling operation output with reachable Cancel. Final full `make linux-test` passed afterward: **116 tests, 5 opt-in skips, zero failures, 261.451s** (`.tmp/ui-polish-final-suite.log`). No Core/backend changes were needed.
- Final `make linux-bundle-dev` exited 0. Restored the macOS `Package.resolved` byte-for-byte after Linux SwiftPM removed it. Reopened `build/linux-dev-bundle/bin/devspace-dev`; handoff frontend/backend PIDs 1832934/1833040 and D-Bus actions `activate-workspace`/`quit` were verified. Existing EGL, stale accessibility-bus and GTK slider warnings remain environmental/runtime observations, not claimed resolved by this UI polish.
- Production executable hashes remain `181c85a88be57c9dd8d7d94584684d35ee4bcf9aef28ad00d743840b99d4901c` and `4edc97fe459fdeba0c8096328cab1f5bce58a7156f95c6876ee42e4b256504f8`. No release build/install or production-targeted quit/kill was performed. The original production processes were absent at the final process check; this task did not restart them.
