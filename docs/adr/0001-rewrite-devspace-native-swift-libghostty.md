# ADR 0001: Rewrite DevSpace as a native macOS Swift app on libghostty

- **Status:** Accepted
- **Date:** 2026-06-27
- **Deciders:** prakhar-pal
- **Supersedes:** the current Tauri 2 (Rust) + React/TypeScript architecture

## Context

DevSpace is a desktop app to manage DevPod workspaces: a live-status sidebar,
start/stop/delete actions, an embedded `ssh <id>.devpod` terminal, and Claude
Code notification routing over a reverse SSH tunnel. Today it is built with
**Tauri 2** — a Rust backend (`src-tauri/`) driving a React/TypeScript frontend
(`src/`) inside a WKWebView, with the terminal rendered by **xterm.js** and its
addons (fit, webgl, unicode11, web-links, clipboard).

The current split is roughly:

- **Backend (~90% portable, working Rust):** `devpod` CLI wrapper, parallel
  status `poller`, `pty` sessions via `portable-pty`, the `notify` HTTP listener
  (`tiny_http` on `127.0.0.1:17865`), idempotent Claude-hook injection
  (`hooks`), sidebar `layout` persistence, and GUI `path_env` repair. None of
  these touch Tauri APIs except through the thin glue in `lib.rs`.
- **Tauri-coupled glue (`lib.rs`, `main.rs`):** 11 `#[tauri::command]`
  handlers, four emitted events (`workspaces-updated`, `pty-output:{id}`,
  `pty-closed:{id}`, `pod-badge`), and plugin init (opener, notification,
  clipboard-manager).
- **Frontend:** React app — `App`, `Sidebar` (drag-reorder, context menus,
  hide/show, aliases), `ActionPanel`, `Terminal` (xterm.js + 5 addons),
  `StartLog`, modals.

We want to move off Tauri. The drivers (below) and a guided design review led to
a specific target rather than a generic "Rust GUI" port.

## Decision drivers

The user identified **all four** of these as motivations for leaving Tauri:

1. **Single language / no JS** — eliminate React/TS/Vite/npm and xterm.js.
2. **Performance / footprint** — escape the webview; lower memory, faster start.
3. **Learning / craft** — this is a personal tool; the build is worth doing well.
4. **Distribution / signing** — simplify the macOS bundle and drop WKWebView.

Two further constraints emerged during review:

5. **Terminal quality is the product.** DevSpace *is* an SSH-terminal manager;
   the terminal is ~80% of the value and ~80% of the rewrite effort. Replacing
   xterm.js+WebGL must not regress quality (truecolor, Unicode/nerd glyphs,
   scrollback, OSC 52 clipboard, focus reporting), and ideally improves it
   (font shaping / programming ligatures).
6. **Platform scope = macOS only.** The app is already macOS-specific
   (`~/Library/Application Support`, dock-bounce fallback, LaunchServices PATH
   quirks). Cross-platform was explicitly weighed and declined (see Option C).

## Considered options

The decision tree has three coupled axes: **(1) terminal engine**, **(2) UI
toolkit / platform scope**, and **(3) backend disposition**. The options below
are the coherent end-to-end combinations considered.

### Option A — Pure Rust: egui/iced + `alacritty_terminal`

A Rust-native GUI (egui via `eframe`, with `egui_term` as the terminal widget,
or iced with `iced_term`) renders the terminal grid *inside its own surface*
using the `alacritty_terminal` crate as the VT engine. The existing Rust backend
is kept essentially unchanged behind a new (non-Tauri) glue layer.

- **Good:** True single language; one toolchain (`cargo`); trivial bundling and
  signing; cross-platform-capable; backend ports nearly verbatim; lowest risk;
  best fit for drivers 1 and 4 and "learning."
- **Bad:** Terminal quality caps below the current bar in one visible way —
  **no programming ligatures** and weaker font shaping (Alacritty's engine never
  shaped ligatures, and egui won't shape FiraCode for free). You own the
  render/input glue (mitigated by `egui_term`). egui's look is utilitarian.
- **Verdict:** Strong on 3 of 4 drivers but loses on driver 5 (terminal
  quality), which is the product's core.

### Option B — Cross-platform UI + libghostty (hard mode)

Keep libghostty's best-in-class engine *and* cross-platform reach by embedding
its native surface (Metal on macOS, GL/GTK on Linux) under a cross-platform
toolkit, writing per-OS native-child-view compositing glue.

- **Good:** Best terminal on every platform; cross-platform.
- **Bad:** No toolkit offers turnkey libghostty embedding, so you pay the
  **foreign-native-subview compositing tax once per platform** — overlays,
  z-order, resize/`drawableSize` sync, visibility — against an embedding API
  that is *explicitly not yet a stable third-party API*. Highest effort and risk
  for a solo dev tool.
- **Verdict:** Worst-of-both-worlds for this project; rejected.

### Option C — macOS-only: SwiftUI/AppKit + libghostty (chosen)

Go *with* the grain of libghostty, whose **reference embedding target is
AppKit/SwiftUI** — the same path Ghostty's own macOS app, **cmux**, **Kytos**,
and **ghostling** use. An `NSView` subclass owns a `ghostty_surface_t`; the OS
composites its `CAMetalLayer`; SwiftUI hosts it via `NSViewRepresentable`.

- **Good:** **Best-in-class terminal for the least terminal work** — GPU
  renderer, CoreText shaping (**ligatures back**), font/emoji/nerd-glyph
  handling, scrollback, selection, OSC 52, focus reporting, and Ghostty's
  config/theme system, all "for free." Cleanest possible macOS bundle/signing
  (drivers 2, 4). Reference integrations exist; a Swift package
  (`libghostty-spm`) can even remove Zig from the pipeline. The terminal surface
  can own the `ssh … -R …` command directly, deleting much PTY plumbing.
- **Bad:** **Not pure Rust** (driver 1 reinterpreted as "single language =
  Swift", not Rust) and **macOS-locked** (driver 6 accepted). One real gotcha:
  the SwiftUI-layout ↔ Metal `drawableSize` contract (blurry/clipped renders if
  wrong). libghostty's embedding API is still maturing.
- **Verdict:** **Chosen.** Given that terminal quality is the product and the
  platform is macOS-only, the reference Swift path turns libghostty from
  "high-risk" (as it would be under Rust/FFI) into "moderate, well-trodden."

#### Sub-decision C.1 — Terminal engine: `alacritty_terminal` vs full libghostty

Decided in favor of **full libghostty** (not the VT-only `libghostty-vt`, and
not `alacritty_terminal`). Rationale: under Swift, the costly part of libghostty
(AppKit glue, native subview) *is the reference path with working examples*, so
its cost collapses while its quality advantage (shaping/ligatures/GPU) remains.
`alacritty_terminal` only wins under a pure-Rust premise (Option A).

#### Sub-decision C.2 — Backend disposition: **rewrite in Swift**

The existing Rust backend could be (i) kept as a C-FFI staticlib, (ii) kept as a
sidecar process over a socket, or (iii) **rewritten in Swift**. Chosen: **(iii)
rewrite in Swift** — single language, single toolchain, cleanest Xcode project
and signing story, no FFI/IPC boundary to design. The cost is re-porting and
re-validating proven logic; the two highest-risk pieces to re-test are the
**reverse-SSH-tunnel notification listener** and the **idempotent Claude-hook
injection / settings merge**.

## Decision outcome

**Chosen: Option C with sub-decisions C.1 (full libghostty) and C.2 (Swift
backend rewrite).**

DevSpace becomes a **native macOS application written in Swift** (SwiftUI for
layout/chrome, AppKit/`NSViewRepresentable` to host the libghostty terminal
surface), with libghostty as the terminal engine and **all backend logic
re-ported to Swift**. Rust and the entire `src/` + `src-tauri/` tree are retired.

### Target architecture (high level)

| Concern | Today (Tauri) | Target (native macOS) |
|---|---|---|
| UI chrome / sidebar / modals | React + Tailwind | SwiftUI |
| Terminal | xterm.js + 5 addons in WKWebView | libghostty `NSView` via `NSViewRepresentable` |
| IPC | Tauri `invoke`/`emit` | direct in-process Swift calls / Combine/observation |
| devpod CLI, poller | Rust `devpod`/`poller` | Swift `Process` + `Codable` JSON |
| PTY / SSH session | `portable-pty` | libghostty surface owns the `ssh -R …` command |
| Notify listener | Rust `tiny_http` :17865 | Swift `Network.framework` listener :17865 |
| Hook injection | Rust `hooks` | Swift (`Process` + `devpod ssh`, base64 write) |
| Token / layout files | Rust file I/O | Swift `FileManager` (same paths, 0600 token) |
| Notifications / dock | Tauri plugins | `UserNotifications` + `NSApplication` attention |
| Build / bundle | Tauri + Vite | Xcode (`cmux`-style `.xcodeproj`) |

### Preserved external contracts (must not change behavior)

- Notify wire protocol: `POST /notify` on desktop `:17865`, pod-side reverse
  tunnel `:8765`, payload `{pod_id, event, token}`, shared-secret token at
  `~/Library/Application Support/DevSpace/notify-token` (mode 0600).
- Event→message mapping: `Stop` → "Claude finished", else "Claude needs your
  input"; hook events `Notification`, `Stop`, `PreToolUse:AskUserQuestion`.
- The DevSpaceDev-only `~/.devspace-notify` in-pod helper script and the
  idempotent settings merge used by both builds.
- SSH invocation flags (`-tt`, `StrictHostKeyChecking=no`,
  `UserKnownHostsFile=/dev/null`, `SetEnv TERM`, `-R 8765:localhost:17865`,
  target `<id>.devpod`).
- Layout persistence (`layout.json`): order, hidden, aliases, hidden_collapsed.
- Dev vs prod distinction (amber "DevSpace Dev" icon/name vs "DevSpace").

## Consequences

**Positive**
- Terminal quality meets or exceeds today's (ligatures, CoreText shaping, GPU),
  with far less terminal code than maintaining xterm.js glue.
- One language (Swift), one toolchain (Xcode); no npm/Vite/Cargo/webview.
- Cleanest macOS bundling/signing/notarization path; lower footprint than a
  webview app.
- Inherits Ghostty config/theme (`~/.config/ghostty/config`) for free.

**Negative / risks**
- **macOS lock-in** — cross-platform is forgone by design.
- **Loss of working, tested Rust** — backend logic must be re-ported and
  re-verified; notify-tunnel and hook-injection idempotency are the riskiest.
- **libghostty maturity** — embedding API is still moving; pin a known-good
  version (or `libghostty-spm`) and track upstream.
- **The `drawableSize` gotcha** — SwiftUI layout ↔ Metal sizing must be correct
  to avoid blurry/clipped rendering; validate early on Retina + resize + sidebar
  toggle.
- **Polyglot-free but new ecosystem** — Zig is needed only if building
  libghostty from source; avoidable via the Swift package.

## Validation plan (suggested first slice)

Before committing the full port, build a minimal spike that:
1. Opens an Xcode SwiftUI app embedding one libghostty surface running
   `ssh <id>.devpod` with the reverse tunnel — confirm crisp Retina rendering,
   resize, ligatures, and focus reporting.
2. Stands up the Swift `Network.framework` notify listener and, from a
   DevSpaceDev build, fires `~/.devspace-notify` end-to-end to confirm the
   tunnel + notification path.
3. Re-ports `hooks` settings-merge with unit tests mirroring the Rust tests
   (preserve unrelated hooks, replace stale DevSpace hooks, handle malformed
   settings).

If the spike confirms terminal quality and the notify path, proceed to port the
sidebar/poller/actions and retire the Tauri tree.

## References

- Mitchell Hashimoto — "libghostty is coming": https://mitchellh.com/writing/libghostty-is-coming
- libghostty C API overview: https://ghostty.org/docs/ (api/overview)
- cmux (Swift + AppKit + libghostty): https://github.com/manaflow-ai/cmux
- ghostling (minimal libghostty C-API app): https://github.com/ghostty-org/ghostling
- Kytos (native macOS terminal on Ghostty): https://jwintz.gitlabpages.inria.fr/jwintz/blog/2026-03-14-kytos-terminal-on-ghostty/
- libghostty-spm (Swift package): https://swiftpackageregistry.com/Lakr233/libghostty-spm
- awesome-libghostty: https://github.com/Uzaaft/awesome-libghostty
