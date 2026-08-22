## Task 1 Report

Implemented the authenticated `/dide` request model and listener routing in `Sources/Core/Notify.swift`, with focused coverage in `Tests/Core/NotifyTests.swift`.

### Files Changed

- `Sources/Core/Notify.swift`
- `Tests/Core/NotifyTests.swift`

### RED

Command:

```bash
env CLANG_MODULE_CACHE_PATH=.tmp/clang-module-cache swift test --scratch-path .tmp/.build --filter NotifyTests
```

Result:

- Failed as expected when the `Notify.swift` implementation was temporarily reverted while keeping the new tests in place.
- The focused test target failed on missing `DidePayload` symbols and the missing `onDide` initializer argument, proving the new tests catch the absent `/dide` implementation.

### GREEN

Command:

```bash
env CLANG_MODULE_CACHE_PATH=.tmp/clang-module-cache swift test --scratch-path .tmp/.build --filter NotifyTests
```

Result:

- Passed after restoring the `/dide` implementation.
- `NotifyTests`: 13 tests executed, 0 failures.

### Notes

- `NotifyListener` now preserves existing `/notify` behavior while routing only `POST /dide` requests to the new `onDide` callback.
- `DidePayload` base64-decodes `path_b64`, rejects non-UTF-8 or non-absolute paths, and requires a token match before callback delivery.
- Rejected `/dide` requests are logged without token or path contents.

### Concerns

- Focused verification required an unsandboxed `swift test` run because the sandboxed SwiftPM manifest/toolchain setup could not complete in this environment.
- The test run still emits an unrelated pre-existing Swift 6 sendability warning in `Tests/Core/ShellIntegrationTests.swift`.
