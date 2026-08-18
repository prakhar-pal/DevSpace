# DevPod SSH Port-Collision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let DevSpace attach to a running DevPod without starting duplicate devcontainer service forwards.

**Architecture:** Keep the existing outer OpenSSH terminal and its reverse notification tunnel. Resolve the alias's effective `proxycommand` with `ssh -G`, accept only a simple DevPod `ssh --stdio` command, then pass that command plus `--start-services=false` back to OpenSSH as a per-process `ProxyCommand` override. Resolve the command off the main actor before creating each terminal pane.

**Tech Stack:** Swift 5.9, Foundation `Process`, SwiftUI/AppModel, XCTest, OpenSSH, DevPod.

## Global Constraints

- Do not alter `~/.ssh/config`, DevPod workspace configuration, or normal user SSH/IDE sessions.
- Keep the outer OpenSSH `-R 8765:localhost:17865` primary-session notification tunnel and `SetEnv=TERM=xterm-256color` unchanged.
- Reject a missing, non-DevPod, or shell-composed `proxycommand`; fall back to the existing alias command and log the reason.
- Run subprocess configuration resolution on a background queue; do not block the SwiftUI main actor.
- Test-first: each production behavior begins with a focused failing XCTest.

---

### Task 1: Safe effective-ProxyCommand parsing and SSH argument construction

**Files:**
- Modify: `Sources/Core/SSH.swift:18-42`
- Modify: `Tests/Core/SSHTests.swift:5-27`

**Interfaces:**
- Consumes: `ssh -G <host>` stdout, whose effective value is formatted as `proxycommand <command>`.
- Produces: `SSH.devpodProxyCommand(effectiveConfig:) -> String?` and `SSH.args(podID:tunnel:proxyCommand:) -> [String]`.

- [ ] **Step 1: Write failing tests for a valid resolved DevPod ProxyCommand**

```swift
func testBuildsArgsWithDevpodServiceForwardingDisabled() {
    let proxy = #"\"/Users/x/.local/bin/devpod\" ssh --stdio --context default --user node wc-1 --workdir \"/workspace\""#
    let args = SSH.args(podID: "wc-1", proxyCommand: proxy)

    XCTAssertTrue(args.contains("-o"))
    XCTAssertTrue(args.contains("ProxyCommand=\(proxy) --start-services=false"))
    XCTAssertTrue(args.contains("-R"))
    XCTAssertEqual(args.last, "wc-1.devpod")
}

func testParsesOnlySimpleDevpodStdioProxyCommand() {
    let config = #"proxycommand \"/Users/x/.local/bin/devpod\" ssh --stdio --context default wc-1"#
    XCTAssertEqual(
        SSH.devpodProxyCommand(effectiveConfig: config),
        #"\"/Users/x/.local/bin/devpod\" ssh --stdio --context default wc-1"#
    )
}
```

- [ ] **Step 2: Run the focused tests and verify they fail because the parser/argument parameter is absent**

Run: `swift test --filter SSHTests/testBuildsArgsWithDevpodServiceForwardingDisabled --filter SSHTests/testParsesOnlySimpleDevpodStdioProxyCommand`

Expected: compile failure referring to the missing `proxyCommand` parameter and `devpodProxyCommand` member.

- [ ] **Step 3: Write failing rejection tests before implementing parsing**

```swift
func testRejectsNonDevpodAndShellComposedProxyCommands() {
    XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand none"))
    XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand ssh jump.example"))
    XCTAssertNil(SSH.devpodProxyCommand(effectiveConfig: "proxycommand devpod ssh --stdio wc-1 ; echo unsafe"))
}

func testSecondaryTerminalRetainsProxyOverrideWithoutReverseTunnel() {
    let args = SSH.args(podID: "wc-1", tunnel: false, proxyCommand: "devpod ssh --stdio wc-1")
    XCTAssertTrue(args.contains("ProxyCommand=devpod ssh --stdio wc-1 --start-services=false"))
    XCTAssertFalse(args.contains("-R"))
}
```

- [ ] **Step 4: Run the rejection tests and verify they fail for the missing implementation**

Run: `swift test --filter SSHTests/testRejectsNonDevpodAndShellComposedProxyCommands --filter SSHTests/testSecondaryTerminalRetainsProxyOverrideWithoutReverseTunnel`

Expected: compile failure referring to the missing parser/argument parameter.

- [ ] **Step 5: Implement the minimal pure parser and argument extension**

```swift
public static func devpodProxyCommand(effectiveConfig: String) -> String? {
    guard let raw = effectiveConfig.split(separator: "\n").first(where: { $0.hasPrefix("proxycommand ") })
        .map({ String($0.dropFirst("proxycommand ".count)) }),
          raw != "none",
          !raw.contains(where: { ";|&<>\n\r".contains($0) }),
          let words = shellWords(raw),
          words.count >= 3,
          (words[0] as NSString).lastPathComponent == "devpod",
          words[1] == "ssh",
          words.contains("--stdio")
    else { return nil }
    return raw
}
```

Implement `shellWords(_:)` as a private quote-aware lexer that accepts plain,
single-quoted, double-quoted, and backslash-escaped tokens, and returns `nil`
for an unclosed quote or escape. Extend `args` with an optional
`proxyCommand`; when non-nil, insert `"-o"` and
`"ProxyCommand=\(proxyCommand) --start-services=false"` before the host.

- [ ] **Step 6: Run all SSH unit tests and verify they pass**

Run: `swift test --filter SSHTests`

Expected: PASS, including existing tunnel, secondary-terminal, workdir, Zed,
and image-copy destination tests.

- [ ] **Step 7: Commit the core behavior and tests**

```bash
git add Sources/Core/SSH.swift Tests/Core/SSHTests.swift
git commit -m "fix: disable DevPod services for app SSH"
```

### Task 2: Resolve the effective command asynchronously before starting panes

**Files:**
- Modify: `Sources/Core/SSH.swift:18-42`
- Modify: `Sources/App/AppModel.swift:755-940`
- Test: `Tests/App/ConnectionTimingTests.swift`

**Interfaces:**
- Consumes: `SSH.resolveDevpodProxyCommand(podID:) -> String?` and existing `SSH.args(podID:tunnel:proxyCommand:)`.
- Produces: every DevSpace terminal pane is created only after its proxy override has been resolved on a non-main queue.

- [ ] **Step 1: Write a failing scheduling test for deferred terminal creation**

Add an injectable `SSHProxyResolving` closure to `AppModel`'s test initializer.
The test resolver records its invocation and delays completion; assert that
`openSSHIfNeeded` does not construct a pane until the completion supplies the
resolved proxy command, then assert that the primary pane is mounted.

```swift
func testConnectWaitsForProxyResolutionBeforeMountingSSHPane() {
    let resolver = DeferredSSHProxyResolver()
    let model = AppModel(sshProxyResolver: resolver.resolve)
    model.connect("wc-1")
    XCTAssertFalse(model.isTerminalVisible("wc-1"))
    resolver.complete(with: "devpod ssh --stdio wc-1")
    XCTAssertTrue(model.isTerminalVisible("wc-1"))
}
```

- [ ] **Step 2: Run the scheduling test and verify it fails because dependency injection/deferred creation do not exist**

Run: `swift test --filter ConnectionTimingTests/testConnectWaitsForProxyResolutionBeforeMountingSSHPane`

Expected: compile failure for `SSHProxyResolving`, the initializer parameter,
or `connect` test seam.

- [ ] **Step 3: Implement asynchronous resolution and stale-result guards**

Add `SSH.resolveDevpodProxyCommand(podID:)`, which runs `/usr/bin/ssh -G
<pod>.devpod`, captures stdout/stderr, returns the validated parser result, and
logs a concise reason for a launch or validation failure. Call it on
`DispatchQueue.global(qos: .userInitiated)`. Dispatch the result to the main
actor, then verify the pod is still `opened`, not stopping, and has no pane
before creating the `TerminalPaneModel` with the optional proxy override.

Move the existing pane construction, hook injection, and terminal-handoff
setup into that main-actor continuation unchanged. Route `newTerminal` through
the same resolver; when the result arrives, append a secondary pane only if the
original primary pane still exists. A nil result must create the existing alias
command without an override, never a direct `devpod ssh` process.

- [ ] **Step 4: Run focused app and core tests and verify they pass**

Run: `swift test --filter ConnectionTimingTests/testConnectWaitsForProxyResolutionBeforeMountingSSHPane --filter SSHTests`

Expected: PASS.

- [ ] **Step 5: Run the full test suite**

Run: `make test`

Expected: all DevSpaceCore and DevSpaceApp tests pass.

- [ ] **Step 6: Commit the asynchronous app wiring and tests**

```bash
git add Sources/Core/SSH.swift Sources/App/AppModel.swift Tests/App/ConnectionTimingTests.swift
git commit -m "fix: resolve DevPod proxy before terminal launch"
```

### Task 3: Validate the real collision path in the dev build

**Files:**
- Modify: `docs/superpowers/specs/2026-08-18-devpod-ssh-port-collision-design.md:58-62`

**Interfaces:**
- Consumes: the completed DevSpace SSH proxy override and the running `wc-2` workspace.
- Produces: a documented manual verification result for the port-collision and notification path.

- [ ] **Step 1: Build the development bundle only**

Run: `make build-dev`

Expected: `build/DevSpaceDev.app` assembles successfully. Do not run a release build or stop the installed production bundle.

- [ ] **Step 2: Hold the workspace forward ports with a normal DevPod terminal**

Run: `ssh wc-2.devpod`

Expected: the ordinary session remains open and owns the devcontainer's configured localhost forwards.

- [ ] **Step 3: Launch the dev bundle through LaunchServices and connect to wc-2**

Run: `open "build/DevSpaceDev.app"`

Expected: DevSpaceDev reaches an interactive wc-2 prompt without a port-bind error or workspace setup/recreation.

- [ ] **Step 4: Verify the primary reverse notification tunnel**

Run inside the DevSpaceDev wc-2 terminal: `~/.devspace-notify Notification`

Expected: DevSpaceDev receives the notification for wc-2.

- [ ] **Step 5: Record the observed acceptance result in the design document and commit it**

```bash
git add docs/superpowers/specs/2026-08-18-devpod-ssh-port-collision-design.md
git commit -m "docs: verify DevPod SSH collision fix"
```
