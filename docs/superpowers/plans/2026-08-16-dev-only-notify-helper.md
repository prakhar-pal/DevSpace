# Development-only DevSpace notification helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install `~/.devspace-notify` only from DevSpaceDev while preserving Claude Code notification hooks in every build.

**Architecture:** The app target owns a compile-time `DEBUG` conditional and passes a Boolean into the portable hook injector. The Core hook injector always merges settings, then conditionally includes only the manual helper write in its remote command.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest.

## Global Constraints

- Do not infer build type from runtime bundle metadata or environment variables.
- Production must continue updating `~/.claude/settings.json` and must not write or chmod `~/.devspace-notify`.
- Do not run `make build` or stop `DevSpace.app`; verify with focused SwiftPM unit tests.
- Do not commit changes; repository instructions reserve commits for the user.

---

### Task 1: Gate manual helper installation by build configuration

**Files:**
- Modify: `Sources/App/AppModel.swift:123-149`
- Modify: `Sources/Core/Hooks.swift:75-95`
- Modify: `Tests/Core/HooksTests.swift`

**Interfaces:**
- Consumes: `Hooks.inject(_:podID:token:)` and `CommandRunning.run(_:)`.
- Produces: `Hooks.inject(_:podID:token:installManualHelper:)`, where `true` writes `~/.devspace-notify` and `false` does not.

- [ ] **Step 1: Write the failing Core tests**

Add a recording `CommandRunning` fake which captures each argument array and returns `{}` for the settings read. Add two tests that call `Hooks.inject` with `installManualHelper: true` and `false`. Both tests assert a `devpod ssh --command` write command contains `settings.json`; only the development test asserts it contains `~/.devspace-notify` and `chmod +x`.

- [ ] **Step 2: Run the focused test target to verify the new tests fail**

Run: `swift test --filter HooksTests`

Expected: compilation failure because `Hooks.inject` has no `installManualHelper` parameter.

- [ ] **Step 3: Add the conditional helper command**

Change `Hooks.inject` to accept `installManualHelper: Bool`. Build its existing settings write command unconditionally, and append the base64 helper write plus `chmod +x ~/.devspace-notify` only when the flag is true. Keep the settings read and JSON merge unchanged.

In `AppModel`, add a private compile-time property:

```swift
#if DEBUG
private let installManualNotifyHelper = true
#else
private let installManualNotifyHelper = false
#endif
```

Pass it into `Hooks.inject`.

- [ ] **Step 4: Run focused tests to verify they pass**

Run: `swift test --filter HooksTests`

Expected: PASS; development retains the helper command and production omits it while both retain the settings write.

- [ ] **Step 5: Run complete unit test suite**

Run: `make test`

Expected: PASS with no new failures.
