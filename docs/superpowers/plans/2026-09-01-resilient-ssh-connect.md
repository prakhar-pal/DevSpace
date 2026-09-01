# Resilient SSH Connect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover from transient pre-ready DevPod SSH exits and report exhausted failures without changing established-terminal exit behavior.

**Architecture:** Track bounded retry state in `AppModel`, schedule generation-guarded retries through an injected scheduler, and expose final failure text to `ActionPanelView`. Gate helper SSH setup on primary output and defer hooks until handoff resolution so the primary transport establishes first.

**Tech Stack:** Swift 6, SwiftUI, XCTest, SwiftPM

## Global Constraints

- Work on `fix/resilient-ssh-connect`; never use `xcodebuild`.
- Use strict red-green-refactor and run `make test` for final verification.
- Retry only a primary SSH exit before handoff completion; never retry established shells.
- Permit two retries at 0.5 and 1.5 seconds, cancelled by user/lifecycle intent changes.

---

### Task 1: Startup retry state machine

**Files:**
- Modify: `Sources/App/AppModel.swift`
- Test: `Tests/App/ConnectionTimingTests.swift`

**Interfaces:**
- Produces: `AppModel.ConnectionRetryScheduling`, retry-attempt/generation state, and `connectionFailure(_:) -> String?`.

- [ ] Write tests that invoke a mounted primary pane's `onExit(255)`, fire a manual retry scheduler, and assert Connecting state, replacement panes, a two-retry cap, final exit-status text, cancellation after Disconnect/stopped status, and a fresh budget after manual Connect.
- [ ] Run `swift test --filter ConnectionTimingTests` and confirm failures reflect missing retry behavior.
- [ ] Implement the minimal generation-checked retry state and lifecycle cleanup while preserving established-pane exit behavior.
- [ ] Re-run `swift test --filter ConnectionTimingTests` until green, then refactor names without changing behavior.

### Task 2: Serialize helper SSH startup

**Files:**
- Modify: `Sources/App/AppModel.swift`
- Test: `Tests/App/SidebarTests.swift`

**Interfaces:**
- Consumes: existing `TerminalHandoffState` and `TerminalPaneModel.onFirstOutput`.
- Produces: one-shot helper startup after primary output and deferred hook injection after handoff resolution.

- [ ] Write tests proving shell integration has not started immediately after Connect, starts once when `onFirstOutput` fires, and timeout reveals the primary without starting integration when no output arrives.
- [ ] Run `swift test --filter SidebarTests` and confirm the sequencing tests fail for the current concurrent behavior.
- [ ] Move integration startup behind the first-output callback, retain the 10-second fail-open timeout, and launch hook injection only after handoff resolution.
- [ ] Re-run `swift test --filter SidebarTests` and `swift test --filter ConnectionTimingTests` until green.

### Task 3: Visible exhausted-failure state

**Files:**
- Modify: `Sources/App/ActionPanel.swift`
- Modify: `Sources/App/ContentView.swift`
- Test: `Tests/App/ActionPanelTests.swift`

**Interfaces:**
- Consumes: `AppModel.connectionFailure(_:) -> String?`.
- Produces: `ActionPanelView.connectionFailure: String?` displayed above connection actions.

- [ ] Write a failing view-policy test showing a final failure retains the Connect action and provides concise exit-status copy.
- [ ] Run `swift test --filter ActionPanelTests` and confirm the expected failure.
- [ ] Pass the model failure into the status card and render it in red without disabling Connect.
- [ ] Re-run `swift test --filter ActionPanelTests` until green.

### Task 4: Verification and review

**Files:**
- Review all modified source, tests, and docs.

- [ ] Run `make test` and confirm all suites pass with no failures.
- [ ] Run `make build-dev` and confirm `build/DevSpaceDev.app` assembles; do not launch or stop the production app.
- [ ] Inspect `git diff --check`, `git status`, and the complete branch diff.
- [ ] Request adversarial code review focused on stale callbacks, retry loops, lifecycle wakeups, and helper-handoff races; fix verified findings and repeat relevant tests.

