# `ded` Helper Deprecation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ded` the injected folder-launch command while retaining `dide` as a warning-only compatibility wrapper.

**Architecture:** `ShellIntegration.managedSnippet` remains the sole producer of the marker-managed Bash/Zsh block. Its folder-launch implementation moves into `ded()`, and a minimal `dide()` wrapper prints the prescribed stderr diagnostic then invokes `ded "$@"`, leaving the `/dide` listener protocol unchanged.

**Tech Stack:** Swift 6, XCTest, Bash, Zsh, SwiftPM.

## Global Constraints

- The desktop endpoint and payload remain `POST /dide` and `DidePayload`.
- `dide` must print `dide is deprecated; use ded instead` on stderr for every invocation.
- The wrapper forwards arguments unchanged and returns `ded`'s status.
- Canonical helper diagnostics use the `ded:` prefix.
- Tokenless injection includes neither helper nor `/dide` request code.

---

### Task 1: Specify canonical and compatibility helper behavior

**Files:**
- Modify: `Tests/Core/ShellIntegrationTests.swift`
- Modify: `Sources/Core/ShellIntegration.swift`

**Interfaces:**
- Produces `ded()` as the canonical generated shell function and `dide()` as its compatibility wrapper.
- Preserves `ShellIntegration.injectScript(podID:token:)` and `/dide` request payloads.

- [ ] **Step 1: Write failing tests**

Rename the current helper tests to `ded`, invoke the generated snippet with `ded`, and assert successful output starts with `ded: opening`. Add a wrapper test for Bash and Zsh which invokes `dide` twice, asserts the warning appears once per invocation on stderr, verifies the POST payload and return status match `ded`, and asserts canonical validation/tunnel/encoding errors use `ded:`.

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `swift test --filter ShellIntegrationTests`

Expected: assertions fail because the snippet only defines `dide()` and its diagnostics use `dide:`.

- [ ] **Step 3: Implement the minimal generator change**

Rename the generated implementation function to `ded()`, change its user-facing usage, path, encoding, tunnel, request, and success diagnostics to `ded:`, and append:

```sh
dide() {
  printf 'dide is deprecated; use ded instead\n' >&2
  ded "$@"
}
```

Do not change the request URL, payload fields, marker delimiters, port resolver, or tokenless branch.

- [ ] **Step 4: Run focused tests to verify green**

Run: `swift test --filter ShellIntegrationTests`

Expected: Bash and Zsh helper tests pass, including the wrapper status and payload assertions.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/ShellIntegration.swift Tests/Core/ShellIntegrationTests.swift
git commit -m "feat: deprecate dide helper"
```

### Task 2: Verify replacement and build integration

**Files:**
- Verify: `Sources/Core/ShellIntegration.swift`
- Verify: `Tests/Core/ShellIntegrationTests.swift`

- [ ] **Step 1: Add/retain marker and tokenless assertions**

Assert the decoded managed block includes both `ded()` and `dide()`, while a tokenless block contains neither command nor `/dide`.

- [ ] **Step 2: Run complete verification**

Run: `make test` and `make build-dev`.

Expected: unit suite passes and `build/DevSpaceDev.app` is assembled; do not launch or stop the production bundle.
