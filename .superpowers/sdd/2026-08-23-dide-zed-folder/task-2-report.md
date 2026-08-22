## Task 2 Report

Implemented the managed `dide` shell helper injection in `Sources/Core/ShellIntegration.swift`, updated the AppModel shell-integration call site to pass `notifyToken`, and added focused coverage in `Tests/Core/ShellIntegrationTests.swift`.

### Files Changed

- `Sources/Core/ShellIntegration.swift`
- `Sources/App/AppModel.swift`
- `Tests/Core/ShellIntegrationTests.swift`

### RED

Command:

```bash
env CLANG_MODULE_CACHE_PATH=.tmp/clang-module-cache swift test --scratch-path .tmp/.build --filter ShellIntegrationTests
```

Result:

- The first focused run was blocked in the managed sandbox because SwiftPM manifest evaluation failed with `sandbox-exec: sandbox_apply: Operation not permitted`.
- The first unsandboxed focused run then failed in the new helper-generation assertions, proving the added tests were exercising the generated payload shape and empty-token behavior.

### GREEN

Command:

```bash
env CLANG_MODULE_CACHE_PATH=.tmp/clang-module-cache swift test --scratch-path .tmp/.build --filter ShellIntegrationTests
```

Result:

- Passed after tightening the payload extraction helper and aligning the managed-snippet assertions to the generated shell source.
- `ShellIntegrationTests`: 6 tests executed, 0 failures.

### Notes

- `ShellIntegration.injectScript(podID:token:)` now preserves the existing OSC 7 shell integration and injects a marker-managed `dide()` helper only when `token` is non-empty.
- The generated helper defaults to `.`, rejects more than one argument, resolves the target with `cd --` and `pwd -P`, base64-encodes the canonical path, and posts the authenticated `/dide` payload to `localhost:8765`.
- `AppModel.injectShellIntegration` now passes `notifyToken`, so production sessions get the authenticated helper while tokenless cases still inject only OSC 7.

### Concerns

- Focused verification required an unsandboxed `swift test` run because SwiftPM manifest evaluation cannot complete under the managed sandbox in this environment.
