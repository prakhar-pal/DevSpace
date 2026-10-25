# Linux sidebar and native keyboard fixes

> **For agentic workers:** Use superpowers:executing-plans inline in this checkout.

**Goal:** Implement the user-approved sidebar design and macOS action parity with
reliable native key delivery, without changing production or workspace lifecycle.

**Architecture:** Reuse WorkspaceWindow's existing actions/popover and the
controller's orderly Quit/Close. Native GTK input tests own a private X display
and bus. Standard GTK button styling replaces flat styling on action buttons.

**Tech Stack:** Swift, GTK4, VTE, existing Swift/native test runners.

**Spec:** docs/superpowers/specs/2026-10-15-linux-sidebar-controls-and-shortcuts.md

## Global constraints

- Current feature branch, no worktree or delegated implementation; production untouched.
- Use the spec's Ctrl+Shift mapping and preserve terminal Ctrl keys and modal editing.
- No real start/stop/recreate/delete and no physical clipboard writes during tests.
- Keep existing sidebar floor, selection highlight, tooltips and action eligibility.
- Use this plan/Git as execution record instead of another scratch ledger/workspace.

## Review focus

- Menu opens for an unselected row without selecting/connecting it.
- Polling while a menu or keyboard-focused control exists does not invalidate callbacks.
- Native shifted symbols/Caps Lock and terminal focus do not lose or duplicate actions.
- Protected window commands work during dialogs; Escape/Return preserve validation.
- Hide/reactivate and Quit/Close preserve orderly backend cleanup and production.

## Task 1 — Discoverable sidebar actions

**Files:** Sources/LinuxApp/WorkspaceWindow.swift;
Tests/LinuxApp/WorkspaceWindowTests.swift; Tests/Linux/test_linux_workspace_window.py.
**Interfaces:** Reuse showWorkspaceMenu(_:relativeTo:x:y:) and existing action contexts.

- [x] Add native sidebar-controls test: ⋮ exists on visible/hidden entries; activation
  opens the target menu, changes no selection/connection, and an action targets its ID.
  Disabled activation cannot act; New/Guide/Stop/⋮ use standard framed buttons.
- [x] Run the new native mode; expect failure for missing ⋮.
- [x] Add sibling icon button, tooltip and callback; retain right-click and remove
  flat CSS only from action buttons. Verify action routing and scrolling.
- [x] Run affected native tests; expect zero failures; commit the verified milestone.

## Task 2 — Native shortcut delivery and missing actions

**Files:** Sources/LinuxApp/WorkspaceWindow.swift, TerminalPane.swift,
LinuxApplication.swift; Tests/LinuxApp/WorkspaceWindowTests.swift,
LinuxApplicationTests.swift and native key test utility; native Python runner;
docs/linux-development.md.
**Interfaces:** Existing handleShortcut(keyval:modifiers:), onCommand and app.quit.

- [x] Add actual private-X11 key delivery tests under terminal/sidebar focus:
  B/R/O/T/1–9, reorder, copy/paste, tab cycling, Ctrl passthrough, Caps Lock,
  modal Escape/Return and protected Q/M/H/W. No handler-only claim of input delivery.
- [x] Reproduce missing/failing actions before production changes; distinguish
  fixture/desktop problems from application event routing.
- [x] Fix demonstrated native delivery defects; implement missing mapped actions
  via GTK/native app lifecycle, plus Ctrl+Tab next-tab alias and modal ownership.
- [x] Run native acceptance/regressions and full Linux suite; update Guide/docs,
  commit, then request one fresh final review of this change range.
- [x] Fix important review findings with RED/GREEN tests, rebuild/open dev bundle;
  record limitations and final results. No production rebuild or PR publishing.

## Execution record

Base: 7cee580. Ruling: the user's request to implement the documented fixes is
approval to proceed with the documented recommended mapping; no additional
approval loop. Cost if wrong: change the modifier mapping, not backend behavior.
Pre-flight: both tasks share WorkspaceWindow; Task 2 preserves Task 1 row identity
and callback ownership. The user forbids worktrees and requested main-thread work;
plan/Git checkpoints supersede generic skill scratch ledgers. One final reviewer
is allowed by executing-plans; no implementation agents.

Task 1 RED: native sidebar test reported missing workspace-menu-pod; GREEN:
its three-dot activation/style/target/disabled checks passed. Task 2 RED:
real input reproduced paste lost with sidebar focus, missing Ctrl+Tab, and
missing Q/W (including modal Quit). Existing B/R/O/T/1–9/reorder and plain
Ctrl passthrough worked after fixing a quoting error in the controlled test
Python shell. This is not evidence that every pre-existing shortcut was broken.
The native test uses runtime libXtst6, already installed on this host; CI adds
it explicitly as a test dependency, not a product dependency. Ruling: both
tasks' native coverage shares one Swift harness; stage the coupled UI milestone
together once its tests pass, rather than commit half of a failing harness.
Cost if wrong: larger first implementation commit, no product behavior change.

Main native acceptance GREEN: all three new tests passed in 36.541 seconds,
including private-display clipboard, real Ctrl passthrough, shifted 1–9 and
Caps Lock, modal Return/Escape, and Q/W orderly shutdown once per app. Native
window tests redirect output to files because portal descendants can inherit
captured pipes after the runner exits; early timeouts from that harness issue
are not application failures.

Full Linux regression GREEN: 114 tests, five opt-in skips, zero failures in
159.938 seconds, including extended modal Hide/reactivation/Close tests. Evidence:
`.tmp/linux-sidebar-input-regression.log`. Package.resolved restored. Both task
implementations and their native checks are verified; one final read-only review
is pending (the first review attempt hit an account usage limit; the user resumed
and the same reviewer was retried). Production bundle has not been rebuilt or
replaced. Physical Wayland key injection and real window-manager minimization
are not claimed by the private Xvfb event tests.

Final fresh review (review_sidebar_native_input, read-only) found one Medium
concern: unchanged polling removed/recreated a keyboard-focused ⋮ control.
Verified RED: `test_sidebar_action_buttons_and_targeted_menu` reported
"unchanged poll destroyed the keyboard-focused menu control". The UI now skips
row rebuilding when display-relevant state is unchanged, preserving the same
focused button. GREEN: native Return activates its correct nonselecting menu;
the sidebar and full key tests passed (31.789 seconds). The paste test now also
checks that its identifying byte occurs once, rather than merely appearing.
Final full Linux rerun remains required for this review fix. No second reviewer.

Final review scope rulings:
- Real DevPod lifecycle effects: no lifecycle commands run against real pods;
  existing payload/eligibility semantics retained. Cost: no new live lifecycle proof.
- Remote SSH cleanup: controlled backend shutdown tested once per Q/W invocation;
  prior wc-1 live checks remain recorded separately. Cost: not reverified live here.
- Production deployment/runtime: existing production untouched and not rebuilt;
  only dev refresh is authorized. Cost: production still has the earlier behavior.
- Unrelated backend behavior: no backend changes in this UI milestone; covered
  by the Linux regressions rather than a new backend audit. Cost: unrelated bugs
  are outside this fix's assurance.
- Terminal-engine bindings: app-owned macOS actions mapped, not Ghostty defaults.
  Cost: engine-specific bindings need separate consideration if requested.
No other credible source defects or deferred minor findings were reported.
Physical Wayland key injection and window-manager minimization remain explicit
acceptance limits, not claims inferred from a bare Xvfb server.

Final review fix verified: full Linux suite passed again, 114 tests, five opt-in
skips, zero failures (179.561 seconds), log `.tmp/linux-sidebar-input-final.log`.
This includes native Return after an unchanged poll preserves the focused menu,
exactly-once paste, dialog Hide/reactivation/Close and orderly app shutdown.
No further reviewer was dispatched. No Core or backend source was changed by
this UI milestone, and no real lifecycle or physical clipboard mutation ran.

Final dev build/assembly passed and DevSpaceDev reopened. Host process checks
confirmed dev frontend/backend PIDs 824770/824863 alongside unchanged production
PIDs 3918940/3919029. Production executable SHA-256 values remain 181c85a8… and
4edc97fe… as previously recorded; no production bundle build, install, replacement
or .deb. Known host EGL/accessibility-bus/GTK-slider diagnostics persist; no claim
of their remediation. Package.resolved restored after the final Swift commands.
All planned implementation steps are complete; branch remains local, no push or
merge. Final fresh review's one source concern was verified and fixed in one pass.
