# Linux port completion audit

Status: implementation substantially complete; visual host-display and
end-to-end integration acceptance remain open. The approved Linux direction is
a DevSpace-owned Swift GTK4 app using VTE only for terminal rendering/input.
Ubuntu 24.04 remains deferred.

The latest default GTK test target passed six checks with authorized `wc-1`
under private Xvfb/D-Bus. Test processes set `GTK_A11Y=none` to avoid sharing a
stale desktop accessibility-bus socket; fatal GLib criticals remain enabled.
This covers the real shell round-trip and terminal close, not accessibility
acceptance on the physical display. The private bus still prints a connection
message during teardown after the successful test result.

The Swift notification action now selects a known workspace and focuses its
existing VTE pane. Its GAction regression rejects an unknown workspace and
records exactly one original terminal connection. Notification-listener
warnings have a separate persistent label; polling no longer erases operation
errors, and explicit retry actions clear the old operation message. Both
regressions were observed failing before their fixes. A final rerun also
exposed a dangling VTE child-exit callback; terminal disposal now disconnects
all owned signal handlers before releasing their objects. The deterministic
disposal regression failed before that change, and the full six-check GTK
suite then passed, including authorized `wc-1` shell acceptance. A physical
notification banner click remains unverified.

The subsequent global-toolchain run passed Core220 tests (one opt-in skip),
protocol4 checks, and Linux73 tests (three opt-in skips), then rebuilt and
assembled the development bundle. `Package.resolved` was restored unchanged.
The Linux CI job and [ADR 0002](../../adr/0002-linux-swift-gtk-vte.md) are now
defined. CI YAML/shell blocks are validated locally, and its corresponding
commands passed on the current host; a GitHub/container run is not claimed.
Production package CI still requires the missing real license/maintainer inputs.

| Area | Verified evidence | Still required |
| --- | --- | --- |
| GTK/VTE app | SwiftPM builds `DevSpaceLinuxApp` and `DevSpaceLinuxBackend` with global Swift.org 6.4.1 for Ubuntu 26.04. The fresh 2026-10-14 `make linux-test` run reported 69 tests and `OK` (three opt-in checks skipped); private-Xvfb coverage includes empty startup, VTE I/O, resize, copy/paste round-trip, private PNG creation for image paste, Ctrl+C passthrough, reconnect shortcut, stale effects, orderly close, and backend failure. A frontend/backend test verifies the generated image is removed after backend completion. The focused GTK test asserts the VTE allocation fills the pane. A real `wc-1` VTE shell round-trip and terminal close passed under Xvfb using the production test identity while DevSpaceDev continued owning the separate development listener; read-only status confirmed the workspace remained Running. The earlier same-channel attempt collided with the already-running DevSpaceDev listener on port 17866 and did not open a pane. | Review the updated bundle's visual layout and close/reopen behavior on the host display; do not repeat a same-channel `wc-1` test while DevSpaceDev owns it. |
| Core/backend | Fresh clean-scratch global Swift 6.4.1 `make linux-test-core` passed 220 tests (one opt-in SSH test skipped; exit 0). The same suite initially stalled in the sandbox at `testCLIStopsAnInFlightDevpodProcess`; outside the sandbox it completed normally. The full Linux suite reported 69 tests with three opt-in checks skipped and `OK`. The authorized wc-1 backend integration passed hook preservation/install, manual notification, `ded`, and clipboard-image upload/cleanup. Static macOS review found no definite functional regression in the AppModel extraction, but noted a P3 memory-retention issue: invalidated workspace generation entries remain in the map for the app lifetime. macOS runtime/build validation remains unavailable on this host. | macOS Core/app build and runtime verification; decide whether to remove the low-priority generation-map tombstones. |
| UI-first actions | GTK rows expose start/open/reconnect/stop. Ctrl+Shift+C/V uses VTE clipboard APIs; image clipboard paste creates a private PNG and routes it through the existing upload command; Ctrl+Shift+R reconnects the bound workspace; plain Ctrl+C remains terminal input. The Swift GAction regression verifies notification selection/focus without a second terminal connection. Listener warnings and operation errors survive polling. Authorized wc-1 backend integration verified hook preservation/install, helper, notification, `ded` and image behavior. Read-only checks confirmed managed Claude settings, shell rc markers, and the development helper; these remain installed as authorized. | Real clipboard/image upload through the visible GTK/VTE app is unverified pending separate approval. Physical clipboard, IME, notification banner activation, and `ded` through the visible app remain manual acceptance. Clipboard replacement was not tested. |
| Packaging | Swift GTK/VTE is the default build and relocatable bundle. Safe replacement/rollback tests pass. Dev/prod bundles were run together on private Xvfb/D-Bus; repeat activation retained one app/backend per channel. `make linux-package` now stages a `.deb` under standard system paths and uses `dpkg-shlibdeps` to derive versioned dependencies from the app and bundled runtime. Twenty build/assembly tests pass, including a real XML-linked ELF fixture, package extraction, relocated launcher, output preservation, and macOS lockfile preservation. Analysis of the actual development binaries/runtime declares `libc6 >= 2.43` and `libxml2-16 >= 2.14.1`, so the current host package targets Ubuntu 26.04. GTK/VTE remain system dependencies. | Actual production package build awaits real project/runtime copyright coverage, maintainer identity, and release-build confirmation. Clean-machine installation, host visual review, CI, and Ubuntu 24.04 validation remain open. |
| Toolchain and release gates | Verification used global `/opt/swift-6.4.1-RELEASE-ubuntu26.04`; no repository-local compiler remains. `Package.resolved` was restored byte-for-byte after Linux SwiftPM runs. | macOS build/runtime verification and Ubuntu 24.04 install/acceptance remain deferred. |

Historical execution notes remain in `.tmp/linux-migration/progress.md`. At the
user's request, repository-local compiler installations and stale processes
were removed; verification uses the global toolchain. The host display is now
unlocked; post-fix visual review and the remaining frontend notification,
`ded`, and clipboard/image flows remain open rather than inferred from the
Xvfb checks. The authorized wc-1 managed integration entries remain installed.
The obsolete Linux Ghostty/Zig frontend, patches, and preparation pipeline have
been retired. The approved UI plan and this audit do not claim macOS or Ubuntu
24.04 release acceptance.
