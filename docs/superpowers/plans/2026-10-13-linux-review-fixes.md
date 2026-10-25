# Linux adversarial review fixes

> Historical review record for the earlier Linux frontend prototype. The
> applicable backend-safety fixes remain in the Swift implementation; the
> Ghostty/Zig app, native patch series, and associated tests were later retired
> in favor of the approved Swift GTK/VTE architecture. The original “no commits”
> note reflected that review session; current milestone commits follow the
> repository's `AGENTS.md` rules.

> Execute inline with superpowers:executing-plans and test-driven-development.

Goal: fix the eight reviewed safety/parity issues without expanding deferred features. The user's request to fix the review approves its proposed corrections. No release builds or production shutdown. Preserve the macOS lockfile. No commits/pushes until requested.

Architecture: retain GTK plus Swift child backend. Use native asynchronous GIO writes, a single Linux workspace window for this milestone, shared lifecycle cleanup, bounded streaming diagnostic tails, and optimistic remote settings concurrency checks. Native window/focus behavior remains in maintained patches, not generated source edits.

- [x] HTTP: isolated backend malformed-length regression reproduced crash; shared parser rejects invalid/ambiguous/oversized framing, subsequent ping survives.
- [x] Window ownership: native second-window and tab-detachment regressions. Present existing workspace window; disable detached tabs and unsupported quick terminals.
- [x] Selection: Open selects; native tab-away/back emits a fresh bound focus event. Core generation-validated callback selects and clears badges, rejects stale panes.
- [x] Lifecycle: Stopped/gone disconnects existing transport and cancels pending reload; Unknown remains connected. No automatic connections to externally started pods.
- [x] Backpressure: bounded asynchronous writes in both directions. Lifecycle overflow fails closed with orderly cleanup; teardown drains output through EOF rather than blocking shutdown.
- [x] Output: real 1 MiB stdout/stderr streaming regression proves bounded 64 KiB tails; full-output commands and UTF-8 chunk delivery retain existing semantics.
- [x] PATH: launcher shares repaired PATH across GTK/backend, preserving explicit entries; login discovery runs with visible DevPod and cannot consume handshake stdin.
- [x] Settings race: exact-byte comparison under cooperative publication lock preserves concurrent edits. Signal regression proves cancellation exits before publication and removes lock.

Each task: failing regression first, smallest fix, targeted GREEN. Final: full Core/Python/client/protocol/native suites and dev bundle. Screen-locked Wayland/macOS runtime acceptance remain external gates, not passing claims.

Initial eight-fix verification: Core 220 tests (one opt-in skip), Python 67 (one opt-in
skip), GTK client 35, native GTK 64, protocol 2; zero failures. Development
bundle rebuilt and relocation/library/protocol checks passed. All 19 maintained
patches applied with fuzz=0; macOS lockfile unchanged. Follow-up review found no
remaining important defect after callback-drain, signal and stdin regressions.
Noncooperating settings writers still require respecting the publication lock
for guaranteed exclusion in the final comparison/rename window. Changes remain
local; no commit, push or PR update performed.

## Subsequent host acceptance and review

The unlocked Ubuntu 26.04 host subsequently passed Core 220/220, native
Wayland SSH acceptance on approved `wc-1`, and the real hook/image integration
test. Live development-app Reload replaced only its owned terminal lease;
the installed notification helper delivered an app-scoped notification to the
desktop service. These results do not prove physical banner appearance/clicks,
IME/font rendering, macOS runtime behavior, or Ubuntu 24.04 compatibility.

Patch 0020 enforces one process/backend owner per channel independently of
inherited Ghostty configuration. All 20 patches applied with fuzz=0. Separate
controlled dev/prod processes coexisted on a private X display and private bus,
and secondary launches reused the channel's owner. Private native fixtures
passed 64 tests, including real text clipboard delivery. Host fixtures now seed
the existing shared token into isolated configuration to preserve installed
hook authentication.

The fresh independent review found three additional issues:

- [x] Clipboard isolation instructions: clear `WAYLAND_DISPLAY` and force
  `GDK_BACKEND=x11` before Xvfb; merely changing `DISPLAY` is insufficient.
- [x] PATH collection: controlled background-stdout regression reproduced a
  three-second delay and discarded profile PATH. Read bounded output while the
  shell runs and finish on complete markers rather than process exit/EOF.
  Targeted test then passed; Linux Python suite passed 70 tests with two opt-in
  skips. Full Core verification is recorded separately in the execution ledger.
- [x] Queued image cleanup: pending frames retain their PNG path until complete
  delivery. Failed writes and queue-overflow discards unlink undelivered files;
  successful delivery transfers cleanup to the backend. Actual-file regressions
  observed RED then GREEN for both paths (overflow also mutation-checked).
  Full private GTK client suite passed 37 tests, protocol 2 tests, and Linux
  Python suite 70 tests with two opt-in skips. Native/bundle integration remains
  separately verified in the execution ledger.

Earlier native fixtures replaced the physical desktop clipboard before that
side effect was noticed; its previous contents were not saved. Further fixture
runs use an explicitly isolated display. Additional physical clipboard testing
requires the user's approval. No full-port completion or merge-readiness claim.
