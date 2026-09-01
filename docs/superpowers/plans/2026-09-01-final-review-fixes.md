# Final Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan inline. The user explicitly requires the current checkout, no worktree, no subagents, and the existing `fix/resilient-ssh-connect` branch.

**Goal:** Close all four findings in the final whole-branch review without changing notification payloads, adding an endpoint or dependency, running a release build, or stopping the production app.

**Architecture:** Keep `PodPortRouting.resolverShell` as the one routing implementation and exercise the exact clients that embed it through real shells with only `curl` replaced at the network boundary. Represent the ActionPanel failure/action/button state as one equatable presentation value that the SwiftUI view consumes directly. Amend operational documentation to describe the dual-port, production-first runtime contract.

**Tech Stack:** Swift 5.9, XCTest, SwiftUI, POSIX `/bin/sh`, Bash, SwiftPM/Make.

## Global Constraints

- Work in the current checkout on `fix/resilient-ssh-connect`; do not create a worktree.
- Do not dispatch subagents or reviewers.
- Do not add a metadata/health API or a dependency.
- Preserve Bash, Zsh, and POSIX shell compatibility.
- Preserve the notification and `dide` payloads and endpoints.
- Do not run `make build` or stop `DevSpace.app`; validate with `make build-dev`.
- Use TDD and capture RED before each production-code fix.

---

### Task 1: Executable generated notification clients and delimiter fix

**Files:**
- Modify: `Tests/Core/HooksTests.swift`
- Modify: `Sources/Core/Hooks.swift`

**Interfaces:**
- Consumes: `Hooks.hookCommand(_:podID:token:)`, `Hooks.notifyHelperScript(podID:token:)`, and the shared `PodPortRouting.resolverShell`.
- Produces: executable regression coverage for the exact generated artifacts and a valid shell boundary before `port="$(__devspace_resolve_port)"`.

- [ ] **Step 1: Add a real generated-client shell harness**

Add `GeneratedNotificationClientHarness` in `HooksTests.swift`. It writes the exact generated helper to a temporary executable file, puts a deterministic `curl` stub first on `PATH`, and records probes, POST URL, and POST payload. Run hook commands with `/bin/sh -c <exact command>` and helpers with `/bin/bash <exact helper file> [event]`; capture termination status, stdout, stderr, probes, and POST data.

- [ ] **Step 2: Add route-behavior tests for both clients**

For the hook and helper separately, cover both-live production precedence, development fallback, and neither-live no-POST behavior. Assert the preserved literal hook payload `{"pod_id":"wc-1","event":"Stop","token":"tok"}`, helper event substitution, exact `http://localhost:<selected-port>/notify` endpoint, exit status `0`, hook silence, and helper sent/failed output.

- [ ] **Step 3: Run the exact hook tests and capture RED**

Run `swift test --filter HooksTests`. Expected: executable hook cases fail under `/bin/sh` because the exact generated command contains the invalid `}port=...` boundary; helper cases remain executable.

- [ ] **Step 4: Add the minimal explicit shell delimiter**

Change `Hooks.hookCommand` to concatenate `PodPortRouting.resolverShell`, an explicit newline, and the existing `port=...; curl ...` command. Update the owning-session comment to describe invocation-time availability routing with production precedence.

- [ ] **Step 5: Run the exact hook tests and capture GREEN**

Run `swift test --filter HooksTests`. Expected: all generated-client tests pass with the preserved payloads, endpoints, exit statuses, and output behavior.

### Task 2: ActionPanel presentation contract

**Files:**
- Modify: `Tests/App/ActionPanelTests.swift`
- Modify: `Sources/App/ActionPanel.swift`

**Interfaces:**
- Consumes: workspace state, connecting state, and optional connection failure.
- Produces: `ActionPanel.presentation(workspaceState:isConnecting:connectionFailure:) -> Presentation`, where `Presentation` contains `connectionFailure`, `connectionAction`, and `isConnectionActionEnabled` and is consumed once by `ActionPanelView.body`.

- [ ] **Step 1: Replace the split policy test with a failing presentation-contract test**

Assert that a running, disconnected workspace with `SSH connection failed (exit 255).` produces the same failure copy, `.connect`, and `true` enabled state from one presentation value. Also assert an empty failure is omitted.

- [ ] **Step 2: Run the focused ActionPanel tests and capture RED**

Run `swift test --filter ActionPanelTests`. Expected: compilation fails because the consolidated `Presentation` API does not exist.

- [ ] **Step 3: Implement and consume the minimal presentation value**

Add the equatable presentation value and builder to `ActionPanel`. In `ActionPanelView.body`, compute it once and use its failure text, action kind, and enabled state for the rendered failure, action label/progress state, and `.disabled` modifier.

- [ ] **Step 4: Run the focused ActionPanel tests and capture GREEN**

Run `swift test --filter ActionPanelTests`. Expected: all tests pass.

### Task 3: Operational documentation and verification

**Files:**
- Modify: `README.md`
- Modify: `docs/adr/0001-rewrite-devspace-native-swift-libghostty.md`
- Create: `.superpowers/sdd/2026-09-01-build-aware-pod-routing/final-fix-report.md`

**Interfaces:**
- Consumes: `SSH.ports(bundleIdentifier:)`, `PodPortRouting.resolverShell`, focused RED/GREEN output, full test output, and development bundle output.
- Produces: current dual-port operating guidance, an explicitly superseded ADR contract clause, and a complete evidence report.

- [ ] **Step 1: Correct the runtime documentation**

Document release desktop/pod ports `17865`/`8765`, development ports `17866`/`8766`, and production-first invocation-time routing with development fallback. Mark the ADR's old single-port tunnel statement as superseded while retaining the unchanged notify payload, token, and event contracts.

- [ ] **Step 2: Run all required verification**

Run focused `swift test --filter HooksTests` and `swift test --filter ActionPanelTests`, then `make test`, then `make build-dev`. Do not run a release build or launch/stop either app.

- [ ] **Step 3: Perform an inline adversarial self-review**

Inspect the complete working-tree diff against the four review findings and both specs. Verify the exact shell artifacts are executed, probes and POSTs are distinguished, no-route remains best-effort, payloads/endpoints are unchanged, the view consumes all three presentation fields, docs no longer claim a single-port/session-owned contract, and no unrelated scope entered the diff.

- [ ] **Step 4: Write the complete fix report**

Record each finding with final file/line evidence, the exact RED and GREEN commands/results, focused/full-suite/build output, files changed, self-review result, and remaining live-integration/release-build concerns.

- [ ] **Step 5: Commit all fixes**

Run `git diff --check`, stage only the planned files, and commit on `fix/resilient-ssh-connect` with `git commit -m "fix: close final review gaps"`. Do not push or submit a PR.
