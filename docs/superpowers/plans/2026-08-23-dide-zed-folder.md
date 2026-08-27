# `dide` Remote Folder Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Inject a secure `dide` shell function into connected DevPods and route validated pod directories to DevSpace so Zed opens the requested remote folder.

**Architecture:** Extend the existing OSC 7 shell-integration injection with a marker-managed `dide` function. The function resolves and validates paths inside the pod, then sends a base64 path in a dedicated authenticated `/dide` reverse-tunnel request. The desktop listener dispatches accepted requests to `AppModel`, which reuses the existing Zed SSH URL builder with an explicit workdir.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, Foundation `URLSession`-free Network.framework listener, shell Bash/Zsh snippets, XCTest, SwiftPM.

## Global Constraints

- Use the existing primary SSH reverse tunnel and `SSH.podForwardPort`; add no listener port or long-lived process.
- Inject into both `~/.bashrc` and `~/.zshrc` through the existing marker-managed shell integration path.
- Accept zero or one argument; default to `.`; require an existing directory and canonicalize with `pwd -P`.
- Resolve relative paths inside the pod before transmission; desktop accepts only absolute paths.
- Authenticate every request with the existing per-installation token and validate the pod ID.
- Never shell-interpolate a received path and never fall back to a different directory for explicit `dide` launches.
- Preserve existing Claude notification, shell integration, Cmd+O, and Zed fallback behavior.

---

### Task 1: Add the authenticated `/dide` request model and listener route

**Files:**
- Modify: `Sources/Core/Notify.swift`
- Test: `Tests/Core/NotifyTests.swift`

**Interfaces:**
- Produce `DidePayload: Equatable` with `podID`, decoded absolute `path`, and `token`; decode the wire fields `pod_id`, `path_b64`, and `token`, base64-decode `path_b64`, and reject non-UTF-8 or non-absolute paths.
- Extend `NotifyListener.init` with an optional `onDide: @escaping (DidePayload) -> Void = { _ in }` callback while preserving existing callers.
- Route only `POST /dide` to `onDide`; keep `POST /notify` behavior unchanged.

- [ ] **Step 1: Write failing parser/listener tests**

Add tests that send a valid `/dide` request with base64-encoded path data and assert the decoded payload, then send malformed JSON, missing/invalid base64, relative decoded paths, wrong-token requests, and `/notify` requests to prove existing notification behavior remains unchanged. Assert the callback is not invoked for malformed or unauthenticated requests.

- [ ] **Step 2: Run focused tests and confirm failure**

Run `swift test --filter NotifyTests`. Expect compilation failures for the missing `DidePayload`/listener route or failing new assertions.

- [ ] **Step 3: Implement minimal request routing**

Change the listener’s request parser to retain the HTTP method/path alongside the body. Decode `DidePayload` only for `POST /dide`, require a valid non-empty absolute path, compare the token to `expectedToken`, and invoke `onDide` only after validation. Return the existing no-content response for every request and log rejected requests without exposing token/path contents.

- [ ] **Step 4: Run focused tests**

Run `swift test --filter NotifyTests`. Expect all notification and dide request tests to pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Notify.swift Tests/Core/NotifyTests.swift
git commit -m "feat: add authenticated dide listener requests"
```

### Task 2: Generate and inject the `dide` Bash/Zsh function

**Files:**
- Modify: `Sources/Core/ShellIntegration.swift`
- Modify: `Sources/App/AppModel.swift` (shell integration call site)
- Test: `Tests/Core/ShellIntegrationTests.swift`

**Interfaces:**
- Produce `ShellIntegration.injectScript(podID: String, token: String) -> String` containing the existing OSC 7 snippet plus the marker-managed `dide` function.
- Update `ShellIntegration.inject(_:podID:token:)` to run the generated script with the existing `--start-services=false` DevPod SSH command.

- [ ] **Step 1: Write failing helper-generation tests**

Assert the generated script contains a `dide()` function, the `/dide` endpoint, the pod ID/token, `cd --`, `pwd -P`, argument-count validation, base64 encoding, and both rc-file targets. Add assertions that the existing OSC 7 marker and self-upgrade commands remain present.

- [ ] **Step 2: Run focused tests and confirm failure**

Run `swift test --filter ShellIntegrationTests`. Expect failures or compile errors because the parameterized generator does not exist yet.

- [ ] **Step 3: Implement the helper**

Generate a shell-safe function that rejects more than one argument, defaults the target to `.`, resolves it with `cd -- "$target" && pwd -P`, prints an error and returns nonzero on failure, base64-encodes the canonical path, and posts JSON containing fixed `pod_id`, `path_b64`, and `token` to `http://localhost:<SSH.podForwardPort>/dide`. Keep the function POSIX-compatible with Bash/Zsh constructs already used by the snippet. Keep existing `injectScript()` compatibility only where tests or non-runtime callers require it; production injection must include the pod/token payload.

Update the AppModel shell-integration call to pass `notifyToken`. If no token exists, retain the existing OSC 7 injection but omit or disable `dide` rather than creating an unauthenticated helper.

- [ ] **Step 4: Run focused tests**

Run `swift test --filter ShellIntegrationTests`. Expect all helper-generation and existing injection argument tests to pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/ShellIntegration.swift Sources/App/AppModel.swift Tests/Core/ShellIntegrationTests.swift
git commit -m "feat: inject dide pod folder helper"
```

### Task 3: Open explicit remote directories in Zed

**Files:**
- Modify: `Sources/App/AppModel.swift`
- Test: `Tests/App/` or an existing AppModel-focused test file

**Interfaces:**
- Add `openInZed(_ id: String, workdir: String?)` (or an equivalent private overload) that preserves `openInZed(_:)` default-directory behavior.
- Add an AppModel listener callback that receives `DidePayload`, rejects invalid/unknown pod IDs, and dispatches explicit workdir opening on the main actor.

- [ ] **Step 1: Write failing explicit-path tests**

Use injected runners/executors to assert an accepted dide payload for a known workspace constructs the exact `SSH.zedRemoteURL(podID:workdir:)` path, while invalid pod IDs, relative desktop paths, and unknown workspaces do not launch Zed. Assert ordinary `openInZed(id)` still uses terminal cwd/DevPod fallback behavior.

- [ ] **Step 2: Run focused tests and confirm failure**

Run the selected AppModel/Zed tests. Expect missing explicit-workdir dispatch or failing URL assertions.

- [ ] **Step 3: Implement explicit launch handling**

Wire `NotifyListener`’s `onDide` callback in `startNotifyListener`. Validate `Devpod.validateId`, membership in the current workspace collection, and an absolute non-empty path. Pass the path to the Zed CLI URL builder without shell interpolation. For explicit paths, do not call `openViaDevpod` with a different default directory when the CLI is unavailable; log the failure or activate an already-open Zed session according to the existing session behavior.

- [ ] **Step 4: Run focused tests**

Run the AppModel/Zed tests and the existing `ZedRemoteTests`. Expect all explicit and legacy paths to pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/AppModel.swift Tests/App Tests/Core/SSHTests.swift
git commit -m "feat: open explicit dide folders in zed"
```

### Task 4: Integration verification and review

**Files:**
- Modify: `.superpowers/sdd/2026-08-23-dide-zed-folder/progress.md` (ignored ledger)
- Test: all existing test targets

- [ ] **Step 1: Run the focused combined suite**

Run `swift test --filter NotifyTests --filter ShellIntegrationTests --filter ZedRemoteTests` and confirm all pass.

- [ ] **Step 2: Run the full suite**

Run `make test` and record the exact passing test count in the SDD ledger.

- [ ] **Step 3: Run hygiene checks**

Run `git diff --check` and inspect `git status --short --branch`; the tracked worktree must be clean after commits.

- [ ] **Step 4: Request adversarial review**

Review the complete feature diff for protocol authentication, shell quoting, reverse-tunnel routing, explicit-path fallback behavior, and regressions in existing notification/Zed flows. Fix any findings before updating the PR.

- [ ] **Step 5: Push the feature branch**

```bash
git push
```
