# Linux port completion audit

Status: implementation substantially complete; visual host-display and
end-to-end integration acceptance remain open. The approved Linux direction is
a DevSpace-owned Swift GTK4 app using VTE only for terminal rendering/input.
Ubuntu 24.04 remains deferred.

| Area | Verified evidence | Still required |
| --- | --- | --- |
| GTK/VTE app | SwiftPM builds `DevSpaceLinuxApp` and `DevSpaceLinuxBackend` with global Swift.org 6.4.1 for Ubuntu 26.04. `make linux-test-gtk` passes 5/5; private-Xvfb coverage includes empty startup, VTE I/O, resize, copy/paste round-trip, Ctrl+C passthrough, reconnect shortcut, stale effects, orderly close, and backend failure. An opt-in test passed an actual `wc-1` shell output/input round-trip through the GTK/VTE app and closed the terminal while leaving the workspace running. The dev bundle is running. | Visual host-layout inspection on an unlocked desktop. |
| Core/backend | `make linux-test-core` passed 220 tests (one opt-in SSH test skipped). Full `make linux-test` passed 69 tests (three opt-in checks skipped). The authorized wc-1 backend integration passed hook preservation/install, manual notification, `ded`, and clipboard-image upload/cleanup. | macOS Core/app regressions. |
| UI-first actions | GTK rows expose start/open/reconnect/stop. Ctrl+Shift+C/V uses VTE clipboard APIs; Ctrl+Shift+R reconnects the bound workspace; plain Ctrl+C remains terminal input. Backend integration through wc-1 verified existing hook/helper, notification, `ded` and image behavior. | Physical desktop clipboard, IME, notification banner activation, and hook/helper/notification/`ded`/image paths through the visible app remain manual acceptance. Clipboard replacement was not tested. |
| Packaging | Swift GTK/VTE is the default build and relocatable bundle. Safe replacement/rollback tests pass. Dev/prod bundles were run together on private Xvfb/D-Bus; repeat activation retained one app/backend per channel. GTK/VTE remain system dependencies. | Release/install workflow, signing/notarization, CI. |
| Toolchain and release gates | Verification used global `/opt/swift-6.4.1-RELEASE-ubuntu26.04`; no repository-local compiler remains. `Package.resolved` was restored byte-for-byte after Linux SwiftPM runs. | macOS build/runtime verification and Ubuntu 24.04 install/acceptance remain deferred. |

Historical execution notes remain in `.tmp/linux-migration/progress.md`. At the
user's request, repository-local compiler installations and stale processes
were removed; verification uses the global toolchain. The host display was
locked during visual inspection, so no unlock or interaction was attempted.
The obsolete Linux Ghostty/Zig frontend, patches, and preparation pipeline have
been retired. The approved UI plan and this audit do not claim macOS or Ubuntu
24.04 release acceptance.
