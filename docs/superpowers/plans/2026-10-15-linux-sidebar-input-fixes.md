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

- [ ] Add native sidebar-controls test: ⋮ exists on visible/hidden entries; activation
  opens the target menu, changes no selection/connection, and an action targets its ID.
  Disabled activation cannot act; New/Guide/Stop/⋮ use standard framed buttons.
- [ ] Run the new native mode; expect failure for missing ⋮.
- [ ] Add sibling icon button, tooltip and callback; retain right-click and remove
  flat CSS only from action buttons. Verify action routing and scrolling.
- [ ] Run affected native tests; expect zero failures; commit the verified milestone.

## Task 2 — Native shortcut delivery and missing actions

**Files:** Sources/LinuxApp/WorkspaceWindow.swift, TerminalPane.swift,
LinuxApplication.swift; Tests/LinuxApp/WorkspaceWindowTests.swift,
LinuxApplicationTests.swift and native key test utility; native Python runner;
docs/linux-development.md.
**Interfaces:** Existing handleShortcut(keyval:modifiers:), onCommand and app.quit.

- [ ] Add actual private-X11 key delivery tests under terminal/sidebar focus:
  B/R/O/T/1–9, reorder, copy/paste, tab cycling, Ctrl passthrough, Caps Lock,
  modal Escape/Return and protected Q/M/H/W. No handler-only claim of input delivery.
- [ ] Reproduce missing/failing actions before production changes; distinguish
  fixture/desktop problems from application event routing.
- [ ] Fix demonstrated native delivery defects; implement missing mapped actions
  via GTK/native app lifecycle, plus Ctrl+Tab next-tab alias and modal ownership.
- [ ] Run native acceptance/regressions and full Linux suite; update Guide/docs,
  commit, then request one fresh final review of this change range.
- [ ] Fix important review findings with RED/GREEN tests, rebuild/open dev bundle;
  record limitations and final results. No production rebuild or PR publishing.

## Execution record

Base: 7cee580. Ruling: the user's request to implement the documented fixes is
approval to proceed with the documented recommended mapping; no additional
approval loop. Cost if wrong: change the modifier mapping, not backend behavior.
Pre-flight: both tasks share WorkspaceWindow; Task 2 preserves Task 1 row identity
and callback ownership. The user forbids worktrees and requested main-thread work;
plan/Git checkpoints supersede generic skill scratch ledgers. One final reviewer
is allowed by executing-plans; no implementation agents.
