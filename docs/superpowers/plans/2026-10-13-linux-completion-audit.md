# Linux port completion audit

Status: implementation substantially complete; visual host-display and
end-to-end integration acceptance remain open. The approved Linux direction is
a DevSpace-owned Swift GTK4 app using VTE only for terminal rendering/input.
Ubuntu 24.04 remains deferred.

| Area | Verified evidence | Still required |
| --- | --- | --- |
| GTK/VTE app | SwiftPM builds `DevSpaceLinuxApp` and `DevSpaceLinuxBackend` with global Swift.org 6.4.1 for Ubuntu 26.04. The full `make linux-test` suite passed 69 tests (three opt-in checks skipped); private-Xvfb coverage includes empty startup, VTE I/O, resize, copy/paste round-trip, private PNG creation for image paste, Ctrl+C passthrough, reconnect shortcut, stale effects, orderly close, and backend failure. A frontend/backend test verifies the generated image is removed after backend completion. The current `DevSpaceLinuxApp` executable also launched in private Xvfb, displayed its window, completed a local fixture handshake and received a workspace snapshot without issuing workspace actions. An earlier opt-in test passed a real `wc-1` shell output/input round-trip through GTK/VTE and closed the terminal while leaving the workspace running. A DevSpaceDev process remains open, but its bundle predates the latest image-paste change and does not verify the current source. | Relaunch the current development bundle and inspect its layout on an unlocked desktop. |
| Core/backend | `make linux-test-core` passed 220 tests (one opt-in SSH test skipped). Full `make linux-test` passed 69 tests (three opt-in checks skipped). The authorized wc-1 backend integration passed hook preservation/install, manual notification, `ded`, and clipboard-image upload/cleanup. | macOS Core/app regressions. |
| UI-first actions | GTK rows expose start/open/reconnect/stop. Ctrl+Shift+C/V uses VTE clipboard APIs; image clipboard paste creates a private PNG and routes it through the existing upload command; Ctrl+Shift+R reconnects the bound workspace; plain Ctrl+C remains terminal input. Earlier backend integration through wc-1 verified existing hook/helper, notification, `ded` and image behavior. | Real `wc-1` image upload through the updated visible GTK/VTE app is not yet verified because wc-1 is stopped. Physical desktop clipboard, IME, notification banner activation, and hook/helper/notification/`ded` paths through the visible app remain manual acceptance. Clipboard replacement was not tested. |
| Packaging | Swift GTK/VTE is the default build and relocatable bundle. Safe replacement/rollback tests pass. Dev/prod bundles were run together on private Xvfb/D-Bus; repeat activation retained one app/backend per channel. A freshly assembled preview bundle also passed launcher, bundled-runtime, GTK-window, and local-fixture snapshot smoke on private Xvfb. GTK/VTE remain system dependencies. | Relaunch the current bundle on the unlocked host; release/install workflow, signing/notarization, CI. |
| Toolchain and release gates | Verification used global `/opt/swift-6.4.1-RELEASE-ubuntu26.04`; no repository-local compiler remains. `Package.resolved` was restored byte-for-byte after Linux SwiftPM runs. | macOS build/runtime verification and Ubuntu 24.04 install/acceptance remain deferred. |

Historical execution notes remain in `.tmp/linux-migration/progress.md`. At the
user's request, repository-local compiler installations and stale processes
were removed; verification uses the global toolchain. The host display was
locked during visual inspection, so no unlock or interaction was attempted.
The obsolete Linux Ghostty/Zig frontend, patches, and preparation pipeline have
been retired. The approved UI plan and this audit do not claim macOS or Ubuntu
24.04 release acceptance.
