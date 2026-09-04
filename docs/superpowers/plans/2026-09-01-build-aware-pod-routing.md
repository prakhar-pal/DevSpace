# Build-Aware Pod Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route `dide` and notification requests through a live production reverse tunnel when available, falling back to the development tunnel, while giving new SSH sessions separate build-specific port variables.

**Architecture:** Add one Core shell-fragment generator that validates the two build-specific port candidates and probes production before development. SSH argument construction exposes only the active build's variable; `ShellIntegration` and `Hooks` embed the shared resolver immediately before sending their existing HTTP requests.

**Tech Stack:** Swift 5.10, SwiftPM/XCTest, Bash/Zsh/POSIX shell fragments, `curl`, Network.framework listener already present in the app.

**Spec:** `docs/superpowers/specs/2026-09-01-build-metadata-routing-design.md`

## Global Constraints

- Production pod port is `8765`; development pod port is `8766`.
- Prefer a live production tunnel; use development only when production is unavailable.
- Do not add a metadata or health API endpoint.
- Do not require `jq`, Python, `nc`, or any new pod dependency.
- Generated routing must work in Bash, Zsh, and POSIX `/bin/sh`.
- Existing notification and `/dide` payloads remain unchanged.
- Run only `make build-dev`; a release `make build` requires separate user confirmation.
- Do not close or kill the production `DevSpace.app`.

---

## File Structure

- Create `Sources/Core/PodPortRouting.swift`: owns build-specific variable names, default pod ports, port validation, probe order, and the reusable shell resolver fragment.
- Create `Tests/Core/PodPortRoutingTests.swift`: executes the resolver with a stub `curl` to verify validation and production-first fallback independently of `dide` and hooks.
- Modify `Sources/Core/SSH.swift`: classify the active bundle channel and emit the corresponding build-specific SSH variable.
- Modify `Tests/Core/SSHTests.swift`: verify production/dev variable selection and removal of the generic variable.
- Modify `Sources/Core/ShellIntegration.swift`: resolve a live port before posting `/dide`.
- Modify `Tests/Core/ShellIntegrationTests.swift`: model liveness probes and assert production precedence, development fallback, and no-route errors in Bash and Zsh.
- Modify `Sources/Core/Hooks.swift`: reuse the resolver for Claude hook and manual-helper notification requests.
- Modify `Tests/Core/HooksTests.swift`: verify the generated clients contain the shared resolver and no generic variable.

### Task 1: Shared Port Resolver and SSH Environment

**Files:**
- Create: `Sources/Core/PodPortRouting.swift`
- Create: `Tests/Core/PodPortRoutingTests.swift`
- Modify: `Sources/Core/SSH.swift:5-65`
- Modify: `Tests/Core/SSHTests.swift:4-45`

**Interfaces:**
- Produces: `PodPortRouting.productionEnvironmentVariable: String`
- Produces: `PodPortRouting.developmentEnvironmentVariable: String`
- Produces: `PodPortRouting.productionPort: UInt16`
- Produces: `PodPortRouting.developmentPort: UInt16`
- Produces: `PodPortRouting.resolverShell: String`, defining `__devspace_resolve_port()`.
- Produces: `SSH.BuildChannel` and `SSH.buildChannel(bundleIdentifier:)` for selecting the SSH variable.

- [ ] **Step 1: Write failing SSH environment tests**

Add explicit bundle-aware argument construction so tests do not depend on the test bundle identifier:

```swift
func testProductionSSHUsesOnlyProductionPortVariable() {
    let args = SSH.args(podID: "wc-1", bundleIdentifier: "com.prakharp.devspace")
    XCTAssertTrue(args.contains("SetEnv=DEVSPACE_PROD_POD_FORWARD_PORT=8765"))
    XCTAssertFalse(args.contains { $0.contains("DEVSPACE_DEV_POD_FORWARD_PORT") })
    XCTAssertFalse(args.contains { $0.contains("DEVSPACE_POD_FORWARD_PORT=") })
}

func testDevelopmentSSHUsesOnlyDevelopmentPortVariable() {
    let args = SSH.args(podID: "wc-1", bundleIdentifier: "com.prakharp.devspace.dev")
    XCTAssertTrue(args.contains("SetEnv=DEVSPACE_DEV_POD_FORWARD_PORT=8766"))
    XCTAssertFalse(args.contains { $0.contains("DEVSPACE_PROD_POD_FORWARD_PORT") })
    XCTAssertFalse(args.contains { $0.contains("DEVSPACE_POD_FORWARD_PORT=") })
}
```

- [ ] **Step 2: Run the SSH tests and verify they fail**

Run:

```bash
swift test --filter SSHTests
```

Expected: compilation fails because `SSH.args(...bundleIdentifier:)` and the new build-specific constants do not exist.

- [ ] **Step 3: Write failing resolver execution tests**

Create a harness in `PodPortRoutingTests.swift` that writes `PodPortRouting.resolverShell` to a temporary script, prepends a stub `curl` to `PATH`, and controls liveness with `DEVSPACE_TEST_LIVE_PORTS`. Cover these assertions:

```swift
XCTAssertEqual(try resolve(livePorts: [8765]), "8765")
XCTAssertEqual(try resolve(livePorts: [8766]), "8766")
XCTAssertEqual(try resolve(livePorts: [8765, 8766]), "8765")
XCTAssertNotEqual(try resolve(livePorts: []).status, 0)
XCTAssertEqual(
    try resolve(
        livePorts: [9876],
        environment: ["DEVSPACE_PROD_POD_FORWARD_PORT": "9876"]
    ).stdout,
    "9876"
)
XCTAssertNotEqual(
    try resolve(
        livePorts: [8765],
        environment: ["DEVSPACE_PROD_POD_FORWARD_PORT": "8765/x"]
    ).status,
    0
)
```

The curl stub must extract the final URL argument, return zero only when its port occurs in `DEVSPACE_TEST_LIVE_PORTS`, and append probed ports to a trace file so the both-live test can assert that `8766` was never probed after `8765` succeeded.

- [ ] **Step 4: Run the resolver tests and verify they fail**

Run:

```bash
swift test --filter PodPortRoutingTests
```

Expected: compilation fails because `PodPortRouting` does not exist.

- [ ] **Step 5: Implement the shared resolver and bundle-aware SSH arguments**

Create `PodPortRouting.swift` with the following shape:

```swift
import Foundation

public enum PodPortRouting {
    public static let productionEnvironmentVariable = "DEVSPACE_PROD_POD_FORWARD_PORT"
    public static let developmentEnvironmentVariable = "DEVSPACE_DEV_POD_FORWARD_PORT"
    public static let productionPort: UInt16 = 8765
    public static let developmentPort: UInt16 = 8766

    static let resolverShell = """
    __devspace_valid_port() {
      case "$1" in ''|*[!0-9]*|??????*) return 1 ;; esac
      [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
    }
    __devspace_resolve_port() {
      __devspace_prod_port="${DEVSPACE_PROD_POD_FORWARD_PORT:-8765}"
      __devspace_dev_port="${DEVSPACE_DEV_POD_FORWARD_PORT:-8766}"
      if __devspace_valid_port "$__devspace_prod_port" &&
         curl -sS --max-time 1 -o /dev/null "http://localhost:$__devspace_prod_port/" 2>/dev/null; then
        printf '%s\n' "$__devspace_prod_port"
        return 0
      fi
      if __devspace_valid_port "$__devspace_dev_port" &&
         curl -sS --max-time 1 -o /dev/null "http://localhost:$__devspace_dev_port/" 2>/dev/null; then
        printf '%s\n' "$__devspace_dev_port"
        return 0
      fi
      return 1
    }
    """
}
```

In `SSH`, add `BuildChannel`, derive it from the bundle identifier, accept an optional `bundleIdentifier` in `args`, and build the one `SetEnv=` argument from `PodPortRouting`. Preserve the existing listener/reverse-tunnel pairs and all unrelated SSH options.

- [ ] **Step 6: Run focused tests and verify they pass**

Run:

```bash
swift test --filter 'SSHTests|PodPortRoutingTests'
```

Expected: all selected tests pass.

- [ ] **Step 7: Commit the resolver and SSH environment**

```bash
git add Sources/Core/PodPortRouting.swift Sources/Core/SSH.swift Tests/Core/PodPortRoutingTests.swift Tests/Core/SSHTests.swift
git commit -m "fix: separate dev and prod tunnel environments"
```

### Task 2: Route `dide` by Live Tunnel Availability

**Files:**
- Modify: `Sources/Core/ShellIntegration.swift:65-115`
- Modify: `Tests/Core/ShellIntegrationTests.swift:17-390`

**Interfaces:**
- Consumes: `PodPortRouting.resolverShell`, which defines `__devspace_resolve_port()` and prints the selected port.
- Produces: a `dide` function that posts to production when live, otherwise development, and fails before POSTing when neither responds.

- [ ] **Step 1: Update the shell harness to distinguish probes from POSTs**

Change the curl stub so a request without `-X POST` is treated as a liveness probe controlled by `DIDE_TEST_LIVE_PORTS`; retain payload and argument capture for the final POST. Replace `sessionPodForwardPort` with separate `productionPodForwardPort`, `developmentPodForwardPort`, and `livePorts` inputs.

- [ ] **Step 2: Write failing Bash/Zsh routing tests**

Add tests that run for both shells:

```swift
let prod = try harness.run(shell: shell, livePorts: [8765, 8766])
XCTAssertEqual(prod.status, 0)
XCTAssertTrue(prod.curlArguments.contains("http://localhost:8765/dide"))

let dev = try harness.run(shell: shell, livePorts: [8766])
XCTAssertEqual(dev.status, 0)
XCTAssertTrue(dev.curlArguments.contains("http://localhost:8766/dide"))

let missing = try harness.run(shell: shell, livePorts: [])
XCTAssertNotEqual(missing.status, 0)
XCTAssertTrue(missing.stderr.contains("dide: no DevSpace connection available"))
XCTAssertNil(missing.payload)
```

Also assert that a live custom production variable wins and that an invalid production variable falls through to a live development variable.

- [ ] **Step 3: Run the focused tests and verify they fail**

Run:

```bash
swift test --filter ShellIntegrationTests
```

Expected: routing tests fail because `dide` still reads `DEVSPACE_POD_FORWARD_PORT` and performs no probe.

- [ ] **Step 4: Embed the resolver in the managed snippet**

Prepend `PodPortRouting.resolverShell` to the generated `dide` code and replace the generic variable lookup with:

```sh
local port
port="$(__devspace_resolve_port)" || {
  printf 'dide: no DevSpace connection available\n' >&2
  return 1
}
```

Keep path canonicalization, Base64 encoding, JSON payload construction, authentication token, request timeout, and success output unchanged.

- [ ] **Step 5: Run the focused tests and verify they pass**

Run:

```bash
swift test --filter ShellIntegrationTests
```

Expected: all shell-integration tests pass in Bash and Zsh.

- [ ] **Step 6: Commit `dide` routing**

```bash
git add Sources/Core/ShellIntegration.swift Tests/Core/ShellIntegrationTests.swift
git commit -m "fix: route dide through an available build"
```

### Task 3: Route Notification Clients Without the Generic Variable

**Files:**
- Modify: `Sources/Core/Hooks.swift:1-90`
- Modify: `Tests/Core/HooksTests.swift:45-180`

**Interfaces:**
- Consumes: `PodPortRouting.resolverShell` and its `__devspace_resolve_port()` function.
- Produces: hook commands and `~/.devspace-notify` content using the same production-first selection policy.

- [ ] **Step 1: Write failing hook-generation tests**

Replace the generic-variable assertion with:

```swift
func testHookCommandResolvesProductionThenDevelopment() {
    let command = Hooks.hookCommand("Stop", podID: "wc-1", token: "tok")
    XCTAssertTrue(command.contains("__devspace_resolve_port"))
    XCTAssertTrue(command.contains("DEVSPACE_PROD_POD_FORWARD_PORT"))
    XCTAssertTrue(command.contains("DEVSPACE_DEV_POD_FORWARD_PORT"))
    XCTAssertFalse(command.contains("DEVSPACE_POD_FORWARD_PORT="))
    XCTAssertTrue(command.contains("port=\"$(__devspace_resolve_port)\""))
}

func testManualHelperUsesSharedResolver() {
    let script = Hooks.notifyHelperScript(podID: "wc-1", token: "tok")
    XCTAssertTrue(script.contains(PodPortRouting.resolverShell))
    XCTAssertTrue(script.contains("port=\"$(__devspace_resolve_port)\""))
}
```

Retain assertions that pod ID, event, token, `/notify`, and `|| true` semantics are preserved.

- [ ] **Step 2: Run hook tests and verify they fail**

Run:

```bash
swift test --filter HooksTests
```

Expected: the new resolver assertions fail because hooks still use the generic variable.

- [ ] **Step 3: Generate hooks and the helper from the shared resolver**

Prefix both generated clients with `PodPortRouting.resolverShell`. Resolve the port before curl:

```sh
port="$(__devspace_resolve_port)" || exit 0
```

For the one-line Claude hook command, separate statements with semicolons and preserve `>/dev/null 2>&1 || true`, ensuring unavailable tunnels remain non-blocking. For the manual helper, print the existing failure message when resolution fails, and do not attempt the notification POST.

- [ ] **Step 4: Run hook tests and verify they pass**

Run:

```bash
swift test --filter HooksTests
```

Expected: all hook tests pass.

- [ ] **Step 5: Commit notification routing**

```bash
git add Sources/Core/Hooks.swift Tests/Core/HooksTests.swift
git commit -m "fix: route pod notifications through a live build"
```

### Task 4: Regression Verification and Development Bundle

**Files:**
- Modify only if a verification failure exposes a defect in files already listed above.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: verified Core behavior and an assembled `build/DevSpaceDev.app`.

- [ ] **Step 1: Run the entire test suite**

```bash
make test
```

Expected: all tests pass with zero failures.

- [ ] **Step 2: Assemble the development app**

```bash
make build-dev
```

Expected: SwiftPM build succeeds, `build/DevSpaceDev.app` is assembled and ad-hoc signed, and no release bundle is built or stopped.

- [ ] **Step 3: Inspect the final diff**

```bash
git diff --check
git status --short --branch
git log --oneline --decorate -8
```

Expected: no whitespace errors, only intended files changed, and all implementation commits are on `fix/resilient-ssh-connect`.
