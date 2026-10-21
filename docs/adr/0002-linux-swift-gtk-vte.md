# ADR 0002: Build the Linux app in Swift with GTK4 and VTE

- **Status:** Accepted
- **Date:** 2026-10-13
- **Decider:** prakhar-pal
- **Supersedes:** ADR 0001's macOS-only platform scope and the Linux Ghostty/Zig prototype, without changing the macOS renderer decision

## Context

The user prioritizes a usable native Linux terminal and asks to keep DevSpace
code in Swift wherever practical. Adapting Ghostty's entire GTK application
introduced a second UI language and substantial application code unrelated to
DevSpace. Linux renderer parity with Ghostty can follow later.

## Decision

Use a DevSpace-owned GTK4 window and sidebar written in Swift. Import GTK4 and
VTE through SwiftPM system-library targets and their C APIs. VTE supplies the
terminal widget and input encoding. It does not supply the app UI.

Keep the shared Swift controller and the existing Swift backend process for
workspace operations, polling, SSH masters, hooks, notifications, and uploads.
The frontend exchanges versioned control messages with that backend. Terminal
bytes stay in the frontend's terminal transport; they do not cross the control pipe.
Each terminal callback is bound to its workspace, pane, and generation, and
owned GTK signal handlers are disconnected before releasing their Swift pane.

### Approved PTY ownership amendment — 2026-10-21

The user approved reusing shared Swift `PTYSession` in the Linux frontend while
retaining GTK/VTE rendering. The host feeds child output unchanged to VTE and
observes bounded OSC52 clipboard writes, since VTE 0.84.0 does not implement
that Herdr copy path. VTE's `commit` signal supplies encoded input to the host
PTY; the host also owns grid resize, cwd/environment, child exit and cleanup.
GTK work runs on its main context. Clipboard writes require a mapped, focused
terminal in the active window; inactive or retired panes cannot change it.
Only strict UTF-8/base64 clipboard text up to 64 KiB is accepted, never remote
clipboard-read requests or primary-selection writes. macOS keeps its renderer
and existing terminal policy; this does not introduce Ghostty on Linux.

macOS retains SwiftUI and libghostty. Linux builds do not resolve Apple terminal
packages and do not use Zig, Ghostty source patches, or a local compiler copy.

## Build and distribution

Current host verification uses global Swift.org 6.4.1 for Ubuntu 26.04, GTK
4.22.4, and VTE 0.84.0. CI targets Ubuntu 26.04 with the official
[`swift:6.4.1-resolute` image](https://www.swift.org/install/linux/ubuntu/26_04/).
GTK/VTE headers and runtime packages come from Ubuntu; their actual versions
are printed by CI. See [development and package commands](../linux-development.md).

The `.deb` pipeline stages DevSpace under `/usr/lib/devspace`, with the launcher,
desktop entry, icons, and notices in standard system paths. It bundles Swift
runtime libraries and uses `dpkg-shlibdeps` to derive versioned system-library
requirements from all shipped ELF files. GTK/VTE remain system dependencies,
and DevPod and optional Zed are installed by the user. Package production
requires real project/runtime copyright coverage and maintainer metadata.

## Consequences

The Linux app uses one application language and native toolkit APIs. Swift owns
UI/backend orchestration and lifetime management; C shims are limited to
demonstrated interop limitations such as the existing PTY shim.

There is no Linux Ghostty patch-update workflow to maintain. When updating
Swift or GTK/VTE, rerun Core, protocol, GTK lifecycle, bundle relocation, and
package dependency checks on the chosen host ABI. A package built against
Ubuntu 26.04 is not evidence of Ubuntu 24.04 compatibility.

Linux Ghostty feature parity, advanced tabs/splits, Ubuntu 24.04 acceptance, and
macOS runtime verification remain separate follow-up gates. Host clipboard,
input methods, notification banner interaction, and installed-package workflows
require their own acceptance evidence.
