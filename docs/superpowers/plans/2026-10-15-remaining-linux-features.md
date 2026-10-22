# Remaining DevSpace Linux Port — Prioritized Milestone Plan

> **For agentic workers:** Use superpowers:executing-plans in the current checkout and main thread. Do not create worktrees or delegate implementation. Inspect macOS source before each milestone; ask only where genuine ambiguity remains. These milestone numbers supersede the original ordering. The user subsequently authorized continuing through all remaining milestones; release/installation and real-workspace mutation still require their separate approvals.

## Direction

Use macOS as the reference for feature behavior, action availability, dialogs and session lifecycle. Implement Linux presentation in Swift with native GTK4 and VTE. The user's importance ratings determine delivery order: prioritize DevSpace integration and daily use over conveniences already available through DevPod CLI.

Reuse existing backend features rather than rebuilding them. Keep libghostty rendering parity and Ubuntu 24.04 validation deferred. Deliver usable, independently verified increments with small conventional commits. Later optional features must not block earlier delivery.

## User priorities

### Execution checkpoint — 2026-10-15

M01 implemented and independently reviewed. Start/Stop controls, operation output
and targeted cancellation use the existing backend. Workspace notifications now
reuse macOS state gating/debounce and foreground suppression. Review fixes retain
hook cleanup eligibility after the last shell exits, close its frontend pane,
allow ready-owned-master integration during transient status, and forget readiness
when an ID is removed. Silent VTE map/resize no longer signals readiness.
Verified: Core234 (one opt-in skip), backend38, native GTK7 (one live skip), and
both development executable builds. No production replacement or real lifecycle
mutation occurred. Live wc-1/hook/banner acceptance remains pending: its latest
read-only status was Stopped. Current-head macOS CI has not yet run for this change.

Ruling: external starts follow the macOS confirmed-status exception rather than
waiting forever for SSH the app intentionally does not open. Intended connections
still wait for output after failure. VTE readiness requires visible child content;
silent/whitespace-only shells wait until visible text instead of reporting readiness
from map/resize events. Cost: such custom shells may delay hook installation.
Verification uses existing scratch caches and the plan/Git checkpoint rather than
adding a new execution workspace or repeated full Linux/package suite runs.

M02 implemented: a real private-clipboard race reproduced text paste into a
hidden workspace before the fix. Image-to-text fallback now performs its own
asynchronous text read and rechecks the live/mapped pane at each completion,
then uses VTE paste_text to preserve bracketed mode. Native checks verify Unicode,
multiline text, byte-exact bracketed framing, selection copy, and callbacks after
hide/disposal. GTK7 passed (one live skip); the Swift app product rebuilt.
The physical host clipboard was not read or replaced. M03 is next.

M03 first increment implemented: Ctrl+Shift+1–9/B/O/R route through a native
window key controller without swallowing ordinary terminal Ctrl keys; editable
controls retain their input. VTE OSC 7 reports generation-bound decoded paths,
and validated open_zed requests preserve Unicode/space-containing folders and
reject stopped/unknown/busy workspaces and relative paths. GTK7 (one live skip),
backend39, and both development product builds passed. M03 is NOT complete:
frontend image-size limits, editor discovery/fallback parity and latest live
integration acceptance remain. M04–M10 remain unimplemented.
The goal controller was queried and still reports paused; direct turn work is
authorized, but automatic continuation requires resuming the goal in the UI.

M03 second increment: a real approximately18 MB private clipboard PNG reproduced
oversized frontend staging. The frontend now shares ImageUpload.maximumBytes
(16 MiB) and rejects oversized encoded PNGs before creating files or upload
requests, displaying a nonfatal error without pasting unrelated clipboard text.
GTK7 passed (one live skip), ImageUploadTests2 passed, and development products
rebuilt. Tests clean their generated PNGs, including the failing oversized case.
M03 remains open for editor discovery/fallback parity and live acceptance;
M04–M10 are not implemented. No release build/installation is claimed.

M03 third increment: Linux editor discovery now honors absolute PATH entries
first, then standard user/system Zed install locations. A private-home native
GTK test failed for a user install outside PATH before the fix, then passed;
it also verifies PATH override precedence and exact remote URL delivery without
launching the user's editor. GTK8 passed (one opt-in live skip, including the
backend regression suite); development products and bundle rebuilt. Missing and
nonzero-exit Zed remain nonfatal. Fallback policy/stale-request parity and live
acceptance still remain before M03 completion. Per the latest user instruction,
open the development build after each verified milestone, preserving production.

M03 editor fallback implemented: CLI requests always target the workspace URL;
missing/failing CLI checks for an existing Zed SSH session off the GTK thread.
An existing session uses the registered Zed desktop application, never DevPod
provisioning. Otherwise only a non-explicit keyboard request may use
Devpod.ideArgs; explicit ded folders report a nonfatal error instead of silently
opening another folder. Keyboard OSC 7 inference is now distinguished from ded.
Per-workspace generations reject completions after disconnect, reload, stop,
workspace unavailability and shutdown. GTK11 passed (one opt-in live skip),
including backend39, exact fallback argv, private desktop activation and a
delayed-failure-after-disconnect check. Read-only wc-1 status remains Stopped;
live image/helper/editor acceptance remains pending, not claimed complete.
Ruling: Linux uses GIO's registered dev.zed.Zed.desktop activation as the native
counterpart to NSWorkspace activation. Cost: a desktop entry that does not
honor single-instance activation may behave differently; no DevPod provisioning
is attempted when an existing remote session is detected.

M04 implemented: running disconnected workspaces expose Connect/retry, owned
connection phases distinguish connecting/disconnecting from idle, and existing
terminal rows offer Disconnect/Reload SSH Session in a right-click menu without
persistent extra sidebar buttons. Busy workspaces reject Connect/Reload.
An explicit Connect during Disconnect is retained until hook cleanup and the old
master's exit; reload still waits for lease release and rejects old callbacks.
Verified: Core235 (one opt-in skip), GTK11 (one live skip, including backend40),
both development products, and the busy-workspace protocol case directly.
No real workspace lifecycle commands were run. Native menu ownership survives
polling and backend failure; disconnect/terminal exit remain SSH-only actions.

Latest user UI adjustment implemented in this increment: establish the sidebar
minimum once at twice its original content-sized width, rather than doubling on
each poll. Native regression reproduced an unset minimum with a 172 px fixture
baseline before the change and now verifies the doubled floor plus terminal
expansion. A later longer name can grow the sidebar without ratcheting its floor.
M05–M10 remain; M03 live wc-1 acceptance is still pending (Stopped on recheck).

M05 implemented scrolling/orderly-relaunch increment: workspace rows now occupy
a vertically scrollable, width-propagating GTK pane; a 40-workspace native test
reproduced missing scrolling before the change and now selects the last row
without lifecycle commands. The doubled minimum and terminal expansion remain
covered. Development windows identify themselves as DevSpaceDev. A scoped
application Quit action routes through existing backend shutdown/cleanup, so
future development relaunches can close cleanly without process termination.
GTK13 passed (two opt-in skips, including backend40). The already-compiled native
controlled terminal also passed on the host Wayland display using a private
D-Bus session and no physical clipboard access. Host GTK emitted slider-size
warnings; this check is not evidence of physical keyboard/IME or banner behavior.
Host X11 acceptance remains separate (private Xvfb X11 is covered). No GTK input
method override is configured in the current environment; no IME changes made.

User-approved production checkpoint after M05: optimized frontend/backend from
code commit 4c9034c built with the global Ubuntu 26.04 Swift 6.4.1 toolchain.
Staged bundle: build/linux-production-bundle-next (inactive output only).
Package: build/devspace_0.7.1_amd64.deb; approved Git maintainer identity and
GPL/Swift/ICU notices were verified in the archive, with host-derived dependencies
including libc6 >= 2.43 and libxml2-16 >= 2.14.1. Assembly16 and relocated-runtime1
passed; staged executables match the optimized build byte for byte. Debian
dependency scanning emitted nonfatal unversioned-private-Swift/unused-link warnings.
Package SHA-256: de02ec5c2333687d408466a827c49f62ea9b18914bf7915d9a977df9620cddc0.
The pre-existing uncommitted licensing-text edits in assemble-linux.py were
preserved and used, not staged into feature commits. The running production app
was neither replaced nor closed, and the package was not installed. Clean-host
installation, current-head CI/macOS and the remaining M07 acceptance are NOT
claimed. This approved build checkpoint does not mark the remaining port complete.

M04 follow-up discovered during M06 source validation: polling still consumes
standing autoConnect intent after a failed master or last terminal exit. The
macOS implementation instead has bounded startup/disruption recovery and
withdraws intent on deliberate disconnect/exit. Reproduce this with focused
regressions and port the bounded policy before calling recovery parity complete;
the earlier M04 checkpoint verifies controls/cleanup ordering, not this gap.

M06 implemented: right-click friendly-name dialog preloads the alias, trims
whitespace like macOS and leaves DevPod IDs unchanged. Cancel and backend failure
during editing cannot submit changes, and workspace shortcuts are suppressed
while modal. Move Up/Down menu eligibility and Ctrl+Shift+Alt+Up/Down are bounded
to visible workspace order. Open in Zed is also reachable from the row menu and
uses the same inferred active-directory payload as the keyboard route. Existing
backend persistence is reused; restart coverage now verifies saved ordering as
well as aliases. GTK14 passed (one real-workspace skip), including backend40 and
the controlled host-X11 check; development products built.
The apparent host-X11 timeout was reproduced with successful native output:
portal descendants retained captured pipe FDs after the tested app exited. The
host-display harness now waits for the process, uses anonymous temporary output
files and cleans only its private process group. It passed without changing the
app renderer. Host Wayland was covered in M05; physical IME/banner checks remain
separate. Production artifacts remain the approved M05 code snapshot 4c9034c.

M04 recovery follow-up, first verified fix: a resolved-but-missing DevPod proxy
previously launched SSH with the original host configuration, without the safe
no-start-services proxy override. A real controlled-transport regression observed
that launch before the guard, then passed with zero master launches and a terminal
launch failure. Core236 passed (one opt-in skip); the backend rebuilt. Resolution
that was not requested and valid resolved proxies retain their existing behavior.
The bounded-recovery protocol regression is now RED (only one attempt occurs
without a poll; macOS requires two bounded startup retries); it is the next task,
not included as a passing result in this fix.

M04 bounded recovery implemented: shared Swift SSHRecoveryBudget supplies the
unchanged macOS startup delays (0.5/1.5 seconds) and disruption delays (3/5/8/13/21).
Linux retries use a fresh read-only DevPod status check, cannot wake stopped pods,
and remain failed after exhaustion instead of restarting on polls. Explicit
Connect starts a new budget; disconnect/reload/stop/removal/shutdown invalidate
late callbacks. Real output, not master readiness alone, establishes/reset the
disruption budget. Last-shell exit after usable output withdraws connection
intent. Unready client failure instead waits for hook cleanup/master exit before
requesting bounded recovery, and an intervening explicit reload cancels it.
Verified: Core243 (one opt-in skip), backend43, GTK14 (two opt-in skips), and both
development products. New regressions observed missing timed retry/unsafe proxy
fallback/unready-client intent withdrawal before their fixes. wc-1 was rechecked
read-only and is still Stopped; live hooks/image acceptance remains unclaimed.
One default SwiftBuild test client stalled with no active compiler; only that
confirmed client was terminated. Core verification used the same global Swift
toolchain's supported, deprecated native engine with the existing test scratch
path. Default make linux-build-dev subsequently passed with SwiftBuild unchanged.
No new compiler/toolchain installation or worktree was created. Current-head
macOS CI is still required for the shared constants reference; no local macOS
execution is claimed. Remaining source features: M08–M10; M07 installation/CI
and physical-input acceptance remain distinct from the already-built package.

M08 implemented: row menus expose Hide/Show and a bottom Hidden section reuses
SidebarLayout.split/hiddenRows and the existing persisted backend commands.
Collapsed sections retain the selected hidden row; expanding/collapsing preserves
the exact VTE pane. A native Swift regression first observed a hidden row still
visible when collapsed, then passed with command-target and no-lifecycle checks.
GTK15 passed (two opt-in skips, including backend43); wc-1 was rechecked using
the source's status --output json syntax and remains Stopped. No live mutation.
The first suite invocation's output reader outlived completed tests because a
portal inherited its pipe; only that confirmed reader was terminated. A fresh
run using a regular diagnostic log exited zero with the recorded suite result.
M09/M10 remain, along with the previously recorded release/live acceptance gaps.

M09 implemented: explicit new_terminal requires a ready owned SSH master;
normal connect remains idempotent. Multiple panes expose a creation-ordered
tab strip with directory/number titles, close and + controls; a single pane
retains the chrome-free layout. Ctrl+Shift+T and Ctrl+PageUp/PageDown create
and cycle tabs. Active identities survive polls and workspace switching;
closing a sibling preserves its master/generation and the remaining shell.
Native tab regression first failed for missing shortcut, backend regression
for unsupported command. Verified: GTK16 (two opt-in skips, backend44),
WorkspaceTerminalControllerTests21, both development products, and a focused
native test with independent local shell round-trips and active-tab editor
directory targeting. No real SSH multi-shell/live hook acceptance is claimed
while wc-1 remains stopped. M10 is the remaining source-feature milestone.

M10 first increment: New/Create and Recreate confirmation dialogs, global
creation progress/cancellation without a selected workspace, and native Guide
with actual Linux bindings are implemented. Validation reuses Devpod.CreateRequest;
Recreate explains container replacement and submits only after confirmation.
Successful recreation restores connection intent, with SSH deferred to confirmed
Running status. Native tests first observed missing New; the backend fixture
observed successful recreation remaining disconnected before the fix. GTK17
passed (two opt-in skips, including backend45). Backend-failure coverage caught
an enabled footer and now verifies it is disabled; the malformed provisioning
snapshot fixture was corrected to include required badges. M10 is NOT complete:
retained failure output and the pre-snapshot duplicate-submit window remain next.

M10 source implementation completed: the application records create/recreate
request IDs immediately, blocking duplicate submission before the first backend
snapshot. Streamed output survives operation removal and failed replies, remains
visible after polling, and is dismissed explicitly; finished failures cannot be
cancelled. Native controller regressions observed both the pending-submit gap
and lost logs before fixes, and cover Create/Recreate failure dismissal. Empty
repositories now disable Create as on macOS, with submit-time validation retained.
Verified: GTK18 (two opt-in skips, including backend45), Core244 (one opt-in skip),
both default-engine development products and relocatable dev bundle, assembly16.
The first full Core attempt was blocked by sandbox CFSocket denial and stalled;
only its identified XCTest/SwiftPM processes were terminated. A fresh run with
local socket permission passed all 244 tests. No production process was stopped.
All planned source features are now implemented. Final fresh review, current
CI/macOS and the previously listed clean-host/live/physical-input acceptance
remain; source completion is not a claim of full release acceptance.

Final fresh whole-branch review found four High and four Medium defects despite
fixture-only Linux98 (four skips) and Core244 passing. One review-fix pass is
in progress: failed-client status/retry ownership; first-shell handoff;
installed desktop identity; mixed-entry hook preservation; provisioning/poll
connection gating; lagged creation discovery; independent shell integration;
and scrolling expanded hidden rows. Live/installed/physical acceptance remains
separate. The user approved a fresh production BUNDLE after fixes, explicitly
NO new .deb build, installation or production shutdown.

First review fixes verified: hook removal now shares injection's per-command
filter, preserving unrelated commands and entry metadata instead of deleting a
mixed group. The new Swift test failed for lost settings, then Hooks30 passed.
The package builder now installs the global desktop filename matching the
GApplication ID; its artifact assertion first failed, then assembly/package
fixture16 passed. This was a temporary test fixture, not a new deliverable .deb.
The remaining six review findings are still open; no release-ready claim.

Client-exit review fix verified: VTE wait status is decoded and sent through the
private terminal protocol. Nonzero client exits preserve the owned master and
connection intent, retry twice at macOS's 0.5/1.5-second delays with stable pane
identity, then expose Retry/Close. Explicit Close is distinct from client failure;
late timers cannot relaunch after close/master exit. A failed slot does not retire
its generation or dispose siblings. Core23 controller tests and three native GTK
tests passed after observing the failed-client-before-master race and VTE's lost
exit status. New retry state clears on real output. First-shell handoff and the
other five remaining review concerns are still being addressed.

First-shell handoff/independent-integration review fixes verified: shell
installation runs independently before Claude hooks, so invalid settings remain
untouched without disabling ded/OSC 7. The first pane stays input-guarded until
successful, generation-bound integration sends the unchanged macOS shell-restart
command, or a 10-second timeout/failure reveals the original. Late completion
cannot restart a revealed/replaced shell. Retry exhaustion also reveals its
failure slot. Core37 controller/shell tests, three focused backend cases, both
dev products, and the native input-guard/handoff test passed. The native probe
uses a child marker plus Return bytes to verify hidden PTY delivery independently
of VTE's deferred unmapped rendering, then verifies output after reveal. No real
workspace shell was restarted. Remaining review fixes: provisioning/poll gating,
creation discovery and expanded hidden-list scrolling.

Provisioning/poll review fix verified: Running status cannot open SSH while its
Start/Recreate is active; an active Create conservatively holds new poll-driven
connections until its target is known/completed. Starting intent is not cleared
merely by an early Running report. The controlled regression first observed a
connecting transport during running Start, then passed alongside Start-readiness
and successful-Recreate regressions (three backend cases; backend product built).
Creation discovery and hidden scrolling remain open. New discovery regressions
are RED for early completion/transient-list failure; they are not passing evidence.

Expanded-hidden review fix verified: hidden rows now have a height-bounded native
scroller above the footer, preserving the existing width propagation and selected
hidden-row rule. A forty-hidden-workspace native regression first found no scroll
path, then passed alongside visible-row scrolling and hide/show terminal-preservation
checks (three native GTK cases). Creation discovery is the remaining review item;
its three Swift policy tests pass, but backend integration is not yet implemented.

Creation-discovery review fix verified: successful provisioning is distinct from
workspace-list visibility. The operation retains its output and request ID in
discovering state; subsequent successful polls resolve the explicit/new unique
ID, with the same three-successful-miss bound as macOS. Transient list failures
do not turn successful up into a failed Create or consume the miss bound.
Ambiguity/exhaustion preserves the previous selection. Cancelling discovery or
shutdown releases its operation without deleting the created workspace.
Early workspace visibility during Create no longer acquires lasting SSH intent
if provisioning is cancelled; success explicitly claims its discovered ID.
Observed RED: three premature-completion cases and cancelled-create connection
intent. Verified: Core17 affected policy/controller/command tests, backend51,
then two additional discovery-bound/shutdown cases; backend rebuilt without the
implicit-strong-capture warning. All eight final-review source fixes are now
implemented. Full post-fix regressions and the approved fresh production BUNDLE
(not .deb) remain before handoff. Current-head macOS CI remains unverified.

Post-fix Core252 passed (one opt-in skip), and both optimized products compiled.
The full fixture-only Linux109 run exposed one invalid resize-test assumption:
it required a transient forced 100x30 grid even after GTK reallocated its child.
A diagnostic reproduced the mismatch with a valid 94x42 PTY at 757x718 pixels.
The test now resizes the actual GTK window and verifies growth, agreement with
VTE's displayed grid and stty size from the child shell; its focused run passed.
The production adapter's unused test-only resize method was removed. A final
full Linux rerun and refreshed optimized frontend are required before bundling.
wc-1 was rechecked read-only and remains Stopped. Existing production PIDs were
confirmed under build/linux-production-bundle, not the inactive next output.

Final local handoff verified, source code 6b806cb: Core252 passed (one opt-in
skip); fixture-only Linux109 passed (four opt-in skips); optimized products and
relocated optimized-runtime1 passed. Production bundle refreshed at
build/linux-production-bundle-next, without a new .deb or installation. Its two
executables match the release build byte-for-byte. The approved copyright
inventory was copied from packaging/debian/copyright into share/doc/devspace
alongside GPL, Swift and complete ICU notices and compared byte-for-byte.
Frontend SHA-256: 181c85a88be57c9dd8d7d94584684d35ee4bcf9aef28ad00d743840b99d4901c.
Backend SHA-256: 4edc97fe459fdeba0c8096328cab1f5bce58a7156f95c6876ee42e4b256504f8.
The old M05 .deb retains its recorded de02ec5c... SHA-256 and was not rebuilt.
The current dev bundle was rebuilt and reopened; host process checks confirmed
new DevSpaceDev/DevSpaceDevBackend alongside the unchanged production PIDs
3442857/3442951 under build/linux-production-bundle. The new production bundle
was NOT launched, replaced into the daily-driver path or installed. Host GTK
still reports the previously observed EGL, stale accessibility-bus and slider
warnings; no renderer/input-method changes were inferred from them.

All source-feature milestones and eight final-review fixes are implemented and
committed locally. Remaining acceptance is explicit: wc-1 remains Stopped, so
live hooks/image/multi-shell checks are pending; physical IME/banner/clipboard,
clean Ubuntu26 installation and current-head macOS/Linux CI are unclaimed.
Updating existing PR111 is awaiting the user's asynchronous publishing approval;
the feature branch is preserved without a push/merge. The existing local stack
tracks only feat/gnu-linux against main and the open PR111. No worktree or new
compiler was created. Package.resolved was restored after the final Swift builds.

### Automated acceptance and release verification — 2026-10-15

Fresh verification of local source e9597ab and production bundle
`build/linux-production-20261015-124312` completed without implementation changes:

- Core: 252 tests, one opt-in skip, zero failures (19.291 seconds).
- Full Linux fixture/native acceptance: 109 tests, four opt-in skips, zero
  failures (260.657 seconds); log `.tmp/linux-acceptance-current.log`.
- Optimized-runtime relocation and isolated backend handshake: one test passed;
  log `.tmp/linux-release-acceptance-current.log`.
- Actual dev and production binaries: private Xvfb/private-D-Bus coexistence,
  repeated activation with one backend per channel and controlled teardown
  passed; log `.tmp/linux-channel-acceptance-current.log`. The initial invocation
  skipped because its single-prefix assumption did not locate the separate dev
  bundle; the rerun supplied both actual paths and executed the test successfully.
- Controlled terminal/quit acceptance on the physical host's Wayland and X11
  displays passed, one test each (72.810/79.278 seconds), using private buses
  and no physical clipboard access; logs `.tmp/linux-host-wayland-acceptance.log`
  and `.tmp/linux-host-x11-acceptance.log`.
- Both production executables match optimized build outputs byte-for-byte,
  retaining the previously recorded frontend/backend SHA-256 hashes. Their ldd
  outputs resolve all dependencies without a repository-local toolchain;
  `desktop-file-validate` passed and the copyright inventory matches its source.
- No production launch, installation, shutdown, real workspace lifecycle change
  or new distributable .deb occurred; the existing .deb SHA-256 is unchanged.
  Package.resolved was restored after SwiftPM removed the macOS-only lockfile.

Read-only host DevPod status confirms wc-1 is Stopped, so real SSH/hook/image/
multi-shell acceptance remains unavailable without starting an authorized pod.
Physical IME/banner/clipboard and clean Ubuntu26 installation remain unverified.
Read-only PR111 inspection found successful Linux/macOS CI on old remote commit
23e3fa5, not current local source. No remote changes were made; publishing current
commits and obtaining current-head CI still requires the pending user approval.

### Live wc-1 acceptance — 2026-10-15

After the user started wc-1, read-only status confirmed Running. Live checks
completed against the existing optimized backend and current native GTK/VTE
runner, without changing application code or rebuilding the production bundle:

- Two backend integration tests passed (39.144 seconds): settings/unrelated-hook
  preservation, real helper notification and ded routing, exact uploaded PNG
  bytes and generated-file cleanup, plus two independent real PTY shells sharing
  one ControlPath/generation. Closing the first shell preserved the second's
  round-trip and disconnect left wc-1 Running.
- The hook test now also waits for the owned master to close, reads settings
  independently afterward, verifies the disconnected remote notification forward
  is gone, preserves unrelated settings/hooks, and checks managed hooks remain
  only when the peer channel still owns a live notification tunnel.
- Full native live GTK/VTE acceptance passed (57.489 seconds): shell round-trip,
  close/reopen with a new pane identity, exact image bytes and cleanup, remote
  helper to sidebar badge, activation back to the existing wc-1 terminal/focus,
  and real remote ded to the expected Zed URI captured by a test executable.
  This is routing/activation evidence, not a physical desktop-banner click or
  proof that a real Zed application window opened.
- Final read-only status confirmed wc-1 Running and wc-2 Stopped; the temporary
  development listener at localhost:17866 was released. No start/stop/recreate/
  delete operation or project-file mutation was performed. Production untouched.

Initial opt-in failures exposed stale test assumptions, not an application fix:
the GTK probe sent input before shell handoff (diagnostic mapped=0, one output
byte), and the backend runner assumed the first injection/notification belonged
to image paste/wc-1. The test now waits for a mapped terminal and filters events
by the expected operation/workspace. The failed runs remain in the timing log;
the successful reruns retain the same real shell/output and PNG assertions.
The final run used a temporary CLI guard: actual metadata/status, discovery
limited to wc-1 and confirmed-stopped wc-2 for alternate sidebar selection,
SSH allowed only for wc-1, all lifecycle commands blocked. The guard was removed.

Post-change fixture/native regression: 110 tests, five opt-in skips, zero
failures (194.051 seconds). Logs: `.tmp/linux-wc1-backend-live-acceptance.log`,
`.tmp/linux-wc1-vte-live-acceptance.log`,
`.tmp/linux-wc1-vte-timing-diagnostic.log`, and
`.tmp/linux-wc1-harness-regression.log`. Package.resolved restored after SwiftPM.
Remaining release gaps: physical clipboard/IME/banner behavior, clean Ubuntu26
installation and current-head Linux/macOS CI; no new .deb or installation.

### Completion checkpoint — 2026-10-19

This checkpoint supersedes historical completion summaries above; those remain
records of the source and acceptance scope tested at their respective dates.
The resumed goal remains active, not achieved. The preceding turn explained the
transport alternatives but did not implement the clipboard fix or complete a
release gate; this turn revalidated the current artifacts and external state.

- Source at audit start: clean `feat/gnu-linux`, HEAD `a0124a7`. The existing
  M01–M10 source features and later UI/shortcut fixes are committed, but the
  newly reported Herdr clipboard interoperability defect is still unfixed.
- Re-ran the private-display clipboard probe against installed VTE 0.84.0 /
  GTK 4.22.4. Both BEL- and ST-terminated OSC 52 writes left the clipboard
  unchanged; native VTE selection and clipboard copy succeeded. Log:
  `.tmp/linux-goal-20261019-clipboard.log`. This confirms the missing OSC 52
  integration, not an independent failure to paste externally supplied text.
- The user requested a TDD fix. The proposed implementation reuses Swift
  `PTYSession` for terminal I/O while retaining VTE rendering, with bounded,
  active-terminal clipboard writes and no remote clipboard reads. The subsequent
  explicit approval request for that transport change has not been answered;
  the scope comparison and automatic goal continuation are not treated as that
  approval. No transport implementation has started.
- Verified production bundle `build/linux-production-20261017-005453` still
  matches the optimized frontend/backend build outputs byte-for-byte. SHA-256:
  frontend `645229ca9a7bb4eefafc3c6053a5bccba2d994f6a6e6b3f3501464522420829c`,
  backend `73d1ce1fdf08c58ae76a52874fcdbce3fc75c1e5839e9335131f5d5361525d81`.
  `desktop-file-validate` passed and its copyright inventory matches
  `packaging/debian/copyright`. An isolated invocation of the actual production
  backend, using its bundled runtime and an ephemeral notification port,
  returned exactly `ready`, `stopped` for handshake/shutdown and exited 0.
  No DevPod connection or running-app shutdown was performed.
- The approved production build/assembly took 33.92 seconds, recorded in
  `.tmp/linux-production-build.time`. No new release build or installation ran
  during this audit. The user's instruction to produce bundles without a `.deb`
  remains in force; the original M07 `.deb` deliverable is deferred, not a reason
  to build one implicitly.
- Read-only GitHub inspection: PR #111 remains OPEN on
  `23e3fa5ed7725a8409f285c019408b1c27378ccf`; Linux GTK/VTE and macOS SwiftPM
  checks both report SUCCESS for that older head. Local source was 37 commits
  ahead at audit start. Publishing current commits through `gh stack submit`
  still needs authorization; those old checks do not verify current-head CI.
- Remaining acceptance: the Herdr fix and its real clipboard path, physical
  Wayland input/IME/notification-banner behavior, a real Zed GUI handoff, clean
  Ubuntu 26.04 installed-app verification, and current-head Linux/macOS CI.
  Ubuntu 24.04 remains deferred. Previous isolated/native/live evidence is
  preserved above, but is not substituted for these missing acceptance gates.

### Clean Ubuntu runtime checkpoint — 2026-10-19

Advanced the independent M07 runtime gate while the terminal transport approval
remains pending. The existing production bundle was tested, not rebuilt,
installed on the host, replaced or stopped.

- Used the official Ubuntu Base `ubuntu-base-26.04.1-base-amd64.tar.gz` from
  `https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/`. Verified its
  SHA256SUMS and detached signature with the host Ubuntu archive keyring;
  signing-key fingerprint `843938DF228D22F7B3742BC0D94AA3F0EFE21092`.
- Installed distribution runtime libraries and Xvfb/D-Bus test utilities into
  a disposable Bubblewrap rootfs. The test had private network, PID, IPC,
  display, session bus and temporary home; no host desktop bus/display,
  workspace credentials, global Swift installation or host library mounts.
  Mounted `build/linux-production-20261017-005453` read-only at `/opt/devspace`.
- Confirmed `swift`, `swiftc`, `cc`, `gcc`, `clang`, `make`, `pkg-config` and
  `devpod` were absent. Both executable `ldd` reports had no missing libraries;
  Swift/Foundation dependencies resolved from `/opt/devspace/lib`.
- Actual runtime versions: Ubuntu 26.04.1, libc6 `2.43-2ubuntu2.3`, GTK
  `4.22.4+ds-0ubuntu0.1`, VTE `0.84.0-2`, libxml2
  `2.15.2+dfsg-0.1ubuntu0.3`. `dpkg --audit` produced no output.
- Production backend returned exactly `ready` and `stopped` for the isolated
  handshake/shutdown requests with `--notify-port 0`; exit 0. The real launcher
  opened a mapped 1120×720 GTK window and spawned `DevSpaceBackend`.
  `gapplication action com.prakharp.devspace quit` on the private bus exited 0
  with no surviving backend child. The complete smoke command exited 0.
- Rootless limitation: package configuration required root/root ownership
  overrides for the system-bus launch helper (0754) and ssh-agent (0755), since
  this single-user namespace cannot map their special groups. Neither helper
  was exercised. Package maintainer scripts also reported unavailable setcap,
  group ownership and host sysctl operations. This is not proof of a normal
  installed-system configuration or SSH-agent integration. No package source
  or application source was modified for the test.
- GUI stderr retained EGL/DRI3 and missing accessibility-bus warnings from the
  headless environment. Successful startup does not establish GPU acceleration
  or accessibility acceptance. The X11 harness enumerates matching windows to
  distinguish GTK's unmapped 1×1 helper from the mapped application window.

Evidence and exact smoke scripts: `.tmp/ubuntu26-runtime.an6NTQ/` (runtime,
dependency, window, child-process and package-configuration logs). The extracted
rootfs and downloaded image are disposable; preserve the small evidence files,
not a repository-local toolchain/runtime installation. Artifact hashes remain
those recorded in the preceding checkpoint.

This completes only the clean-runtime startup/dependency/shutdown portion of
M07. Installed-app M01–M06 DevPod workflows, real desktop acceptance, the Herdr
clipboard fix and current-head CI remain unverified/incomplete. No `.deb` was
built and no PR was published.

### Release-acceptance goal update — 2026-10-21

The active goal is finishing release acceptance, not reimplementing M01–M10.
Preserve Swift/GTK/VTE and macOS behavior; `.deb`, Ubuntu 24.04 and Ghostty
parity remain deferred. Obtain approval before changing PTY ownership,
publishing changes or replacing production. Existing evidence above remains
historical, not a substitute for testing the eventual clipboard fix.

P06 explicitly includes these separate real-workspace paths:

- [x] Print a known Unicode/multiline marker in an authorized running DevPod,
  select its output in the DevSpace terminal, copy, and paste into another
  DevSpace terminal. Check the destination's received text, not just selection
  state or a clipboard API return value.
- [ ] Select/copy inside Herdr running in that DevPod and paste back into Herdr
  and into a DevSpace shell. Assert the actual destination text. This must
  exercise Herdr's own copy path, not replace it with VTE select-all.
- [ ] Copy from Herdr in DevSpace and paste into another desktop application;
  separately paste externally copied text into the active DevPod terminal.
  Verify physical-desktop behavior with clipboard-test authorization; private
  Xvfb clipboard tests alone do not prove this path.
- [ ] Cover stale/hidden/closed terminals, multiline/Unicode text and bracketed
  paste in automated Swift regressions; retain ordinary terminal control keys,
  input, resize, working directory, output delivery and shutdown behavior.

Existing `WorkspaceWindowTests.swift` covers local-child/private-clipboard
selection and paste, including Unicode and bracketed framing, but does not
establish the remote Herdr or external-desktop paths above. Live tests must
avoid executing pasted markers as arbitrary shell commands or modifying
project files. Use an input-capture process or non-executing text destination.

On 2026-10-21, read-only `devpod status wc-1 --output json --timeout 10s`
reported `Stopped`. Do not start it implicitly. The terminal-transport approval
request remains unanswered; the updated goal does not grant that approval.
Other remaining gates are physical input/notifications/Zed, installed-bundle
DevPod workflows on Ubuntu 26.04, and current-commit Linux/macOS CI after
authorized publication. No acceptance item above is marked complete.

### Approved clipboard transport amendment — 2026-10-21

The user approved keeping GTK/VTE rendering and moving Linux PTY ownership to
the shared Swift `PTYSession`, with TDD coverage for clipboard, typing, resize
and shutdown. They also authorized starting `wc-1` for future tests. This
supersedes the pending-transport-approval entries above, not the separate gates
on publication, release builds, host installation or production replacement.

Execute in this checkout/main thread:

- [x] Add `TerminalClipboardDecoder.consume(Data) -> [String]` in Core and
  `TerminalClipboardTests`: BEL/ST and every chunk boundary, clipboard-only
  selectors, strict UTF-8/base64, no NUL/read queries, 64 KiB decoded limit,
  bounded buffering/recovery and no nested control-string clipboard execution.
  Observe RED with an empty compiling interface, implement, run Core tests,
  restore Package.resolved and commit the decoder milestone.
- [x] Add a native `WorkspaceWindowTests` OSC52 mode that spawns a real child,
  checks private clipboard text and pastes it back into an input-capture child.
  Observe RED on the existing VTE-owned transport. Add tests for hidden/retired
  panes and ordinary selection; do not touch the physical clipboard.
- [x] Extend shared PTY start with working-directory support and a reported PID
  while retaining existing call-site defaults. Test cwd/environment, input,
  actual child resize, complete output before exit and single exit/cleanup.
  Wire VTE `commit` to Swift PTY input, feed output unchanged to VTE while
  observing OSC52, and synchronize VTE grid size with PTY size. Marshal GTK
  work onto its main context; reject clipboard writes from nonactive panes.
  Preserve launch errors and per-pane generation ownership. Run affected native
  checks and full shared Core/lifecycle regressions before committing.
- [ ] Run remote copy/paste and emitted-OSC52 acceptance against running `wc-1`,
  then actual Herdr and physical desktop acceptance with the required scope.
  Open a development build after the milestone; never replace production or
  publish implicitly. Document exact evidence and remaining release gates.

Decoder evidence: compiling empty interface produced 88 assertion failures in
four tests; implemented decoder passed all four. Full Core suite: 257 tests,
one opt-in skip, zero failures (17.610 seconds),
`.tmp/clipboard-core-suite.log`. Native pane RED:
`test_child_osc52_clipboard_roundtrip_and_hidden_pane_isolation` fails with
`child OSC52 did not reach the clipboard`, `.tmp/clipboard-native-red.log`.
SSH readiness to `wc-1` was independently confirmed with a harmless marker;
no live clipboard pass is claimed yet.

PTY prerequisite evidence: `testExitWaitsForOutputCallbackToFinish` exposed a
Linux timer/reap race (exit overtook the blocked output callback), then passed
after deferring Linux exit delivery until output drains. Six PTY tests pass;
full Core suite: 258 tests, one opt-in skip, zero failures (17.953 seconds),
`.tmp/pty-ordering-core-suite.log`. macOS callback logic was left unchanged.

Transport implementation and review evidence — 2026-10-21:

- Shared PTY cwd/environment, Unicode input and actual child resize passed
  after a cwd regression failed. TERM-ignoring child and leader-exited/descendant
  cleanup each reproduced a failure before the Linux cleanup fix. Child exit
  observation now reserves the leader PID until output/descendants drain.
- Independent review found noncanonical base64 padding and ESC+BEL acceptance;
  both have failing-then-passing decoder regressions. Descriptor write/resize
  and close now share an I/O lock. Ruling: that descriptor fix is validated by
  its source locking invariant and regression suites, not a deterministic
  forced FD-reuse test; a race-specific test remains absent.
- A 32-cycle fast-child test exposed VTE's asynchronous feed parsing: final
  output could be lost before the exit callback. Changing idle priority alone
  did not fix it. A supported VTE extension termprop now marks the exact parser
  drain boundary before reporting exit. Native OSC52, deferred launch errors
  and fast-exit checks pass (`.tmp/clipboard-drain-native-green.log`).
- Full reviewed Core suite: 261 tests, one opt-in skip, zero failures,
  18.882 seconds (`.tmp/clipboard-reviewed-core-suite.log`). Full Linux suite:
  121 tests, seven opt-in skips, zero failures, 213.650 seconds
  (`.tmp/clipboard-reviewed-linux-suite.log`).
- Final-source live `wc-1` private-display round-trip passed in 54.201 seconds
  (`.tmp/clipboard-reviewed-wc1.log`): remote OSC52, native selection of remote
  output, and multiline/Unicode paste into a non-executing remote input loop.
  This is not actual Herdr mouse-selection or external-desktop acceptance.
- Physical Wayland checks remain failing/unresolved. One run reached internal
  clipboard success but failed the external xclip read; the subsequent real
  Start-button run failed earlier waiting for the child copy acknowledgment.
  The final diagnostic run could not acquire desktop window focus at all
  (`.tmp/clipboard-host-final-diagnostic.log`); it did not exercise clipboard
  exchange. No conclusion about the earlier external-read failure follows.
  Do not treat private-display success as proof of cross-app desktop behavior.
- Final review: minor (deferred): closed-pane clipboard coverage checks a
  sentinel after disposal but does not force an already queued late OSC52
  callback; hidden-pane coverage waits for positive child acknowledgment.
- The user explicitly approved updating existing PR #111 through
  `gh stack submit` after verification and commit. This supersedes the pending
  publication approval above; merge and production replacement remain forbidden.

Remaining acceptance gates: actual Herdr selection/paste, physical clipboard,
IME/banner and Zed GUI behavior, installed current-bundle DevPod workflows,
and exact-published-commit Linux/macOS CI. No release completion is claimed.

Milestone handoff: Core hardening committed as `ffcb8ec`; fresh Core run passed
261 tests (one skip) in 20.904 seconds. Final affected native run passed all
four checks, including real `wc-1`, in 56.065 seconds
(`.tmp/clipboard-native-milestone.log`). `make linux-bundle-dev` completed and
the development-only `DevSpaceDev` process was opened/observed running. Its
host startup log still contains existing EGL, accessibility-bus and GTK slider
warnings; process presence is not visual or clipboard acceptance.
PR #111 submission remains pending the user's verification condition; no push,
merge, production build, installation or production replacement occurred.

Manual acceptance update — 2026-10-21: after being asked to copy harmless
text from Herdr in the development build into another app and paste back, the
user confirmed: "yes, copy/paste works across apps on devspace now". Record
this as user-observed desktop acceptance on development source `6f9fe26`,
not a passing automated xclip test. The automated physical-desktop harness
limitations above remain unresolved. This satisfies the clipboard publication
condition; proceed with the already authorized PR #111 stack submission and
verify CI against its exact published head. IME/banner, Zed GUI, installed
current-bundle workflows and release verification remain separate gates.

### Release acceptance resumed — 2026-10-22

Application source under acceptance: `79303ca`, on Ubuntu 26.04.1 with the
global Swift 6.4.1 toolchain. No application source changed in this increment.

- PR #111 and [CI run 39615001191](https://github.com/prakhar-pal/DevSpace/actions/runs/39615001191)
  both identify head `79303ca36c0fa84dad661b8ee2fc81433761f6a6`.
  Linux GTK/VTE and macOS SwiftPM jobs both completed successfully. New
  acceptance-test/documentation changes in this increment are not yet published.
- Three focused native checks passed: snapshot/terminal lifecycle, OSC52
  clipboard isolation, and real keyboard delivery. The initial remote attempt
  failed because the authorized workspace start still held DevPod's lock;
  Kubernetes first lacked scheduling capacity, then created the container.
  `devpod up --ide none -- wc-1` subsequently exited successfully; status
  reported Running and an independent SSH marker succeeded.
- Fresh remote clipboard acceptance then passed (54.442 seconds). Added Swift
  assertions now also paste the native selection into a distinct second
  terminal and verify that remote child's received Unicode/multiline text.
  Final focused local/real-wc-1 checks: two tests, zero failures, 68.039 seconds
  (`.tmp/release-acceptance-20261022-cross-pane.log`). The Python launcher allows
  both remote readiness windows; clipboard assertions remain in Swift. An
  earlier compile attempt was discarded after a test-source edit during build;
  the final run used the finished Swift source.
- The host Wayland controlled terminal/quit check passed (47.438 seconds,
  `.tmp/release-acceptance-20261022-wayland.log`). This does not prove physical
  IME composition, desktop clipboard interoperability or banner activation.
- With explicit build/install approval, `make install` produced fresh release
  binaries and installed only under `.tmp/release-acceptance-79303ca`.
  Frontend/backend load that prefix's bundled Swift runtime and system GTK/VTE;
  its desktop entry points to that prefix. The installed backend's real
  production-channel handshake, ping and shutdown succeeded with an ephemeral
  local notification listener and isolated configuration; no DevPod poll or
  connection was requested in that smoke check.
- The installed release frontend and development frontend passed the existing
  private-display/private-bus coexistence and repeat-launch check (one test,
  3.160 seconds, `.tmp/release-acceptance-20261022-channels.log`). Its backend
  is controlled, so this is not installed-bundle real-DevPod acceptance.
- The user's production frontend/backend (PIDs 4482/4559) remained running.
  No production replacement, `.deb`, Ubuntu 24.04 or Ghostty work occurred.

At that checkpoint, installed-backend integration was awaiting explicit approval
to reuse the owner's notification token in wc-1's hooks. That approval has now
been received; the results below supersede that blocker.

### Installed-bundle integration acceptance — 2026-10-22

- Published test/docs head `090858de90ca2c68c358ef5cf5e400da94989904` passed both
  Linux GTK/VTE and macOS SwiftPM CI in
  [run 39672809494](https://github.com/prakhar-pal/DevSpace/actions/runs/39672809494).
  Rechecked the run's exact SHA and successful checks. Its application, package,
  Makefile and script sources are unchanged from installed snapshot `79303ca`.
- With explicit token-reuse approval, started the stopped wc-1 using the
  previously authorized DevPod start command. Startup exited successfully;
  status reported Running and an independent SSH marker succeeded before tests.
- The actual isolated installed frontend **and backend**, using their bundled
  Swift runtime, passed native keyboard-driven remote Unicode OSC52 copy,
  external clipboard ownership, paste acknowledged by the remote child, and
  shortcut-driven orderly shutdown. Evidence:
  `.tmp/release-real-installed-acceptance.log`. This ran on private Xvfb/D-Bus,
  with development channel identity to coexist with the user's production app.
  It is not a physical-desktop clipboard test or production replacement.
- Existing Swift frontend integration assertions also passed against the actual
  installed backend: shell round-trip, terminal close without stopping wc-1,
  reconnect with a new terminal, authenticated helper notification/badge,
  authenticated `ded /tmp` routing to the exact Zed SSH URL, and workspace
  activation/focus. One test, zero failures/errors/skips:
  `.tmp/release-installed-backend-integration.log`. This uses a source-built
  frontend harness and a Zed argument recorder, not the installed frontend or
  a real Zed window. Only wc-1 and independently verified stopped wc-2 were
  listed; wc-2 was selected without connecting. The initial temporary launcher
  incorrectly set opt-in variables after test import and skipped; that run was
  discarded and the corrected launcher required a non-skipped result.
- A separate earlier installed-frontend controlled-peer check opened a real
  Zed window connected to `wc-1.devpod/tmp`; screenshot:
  `.tmp/zed-release-acceptance/remote-window-1.25.2.png`. It verifies the GUI
  handoff, not authenticated `ded` end-to-end in that same run. Zed's updater
  unexpectedly updated the user's Zed 1.24.2 to 1.25.2 during that test; this
  side effect was disclosed, and auto-update was disabled in the test profile
  before retesting 1.25.2. No claim of an unchanged Zed installation is made.
- Opened the isolated installed app on host Wayland with development identity.
  Selected stopped wc-2, then invoked wc-1's authenticated helper through the
  development reverse tunnel. The helper reported success, and a D-Bus monitor
  restricted to this app captured its `Notify` call to the real host service:
  title `wc-1`, body `Claude finished`, default action and development desktop
  identity. Evidence: `.tmp/release-installed-notification-delivery.log`.
  This proves submission, not visible banner display or a physical click;
  user confirmation of banner activation/focus was requested separately.
- Repeated the host banner test at the user's request. wc-1 was Running and
  wc-2 was Stopped. Reopened the existing isolated bundle, selected wc-2 without
  connecting, and sent the authenticated wc-1 `Stop` event. The scoped monitor
  captured `Notify` followed by `ActionInvoked` (`default`, notification ID 18):
  `.tmp/release-installed-notification-retry-delivery.log`. The user explicitly
  confirmed that clicking the banner selected wc-1 and focused its terminal.
  The physical banner-activation gate is now passed; this is manual acceptance
  corroborated by the desktop service's action signal, not a simulated click.
- Both CI jobs passed published documentation head
  `c15277937a9b677428650f0f2790f6702d490e95` in
  [run 39766441351](https://github.com/prakhar-pal/DevSpace/actions/runs/39766441351):
  Linux 5m47s and macOS 1m12s. The subsequent banner-confirmation note changes
  documentation only; it does not change the tested application binaries.

No application code changed for this acceptance increment. The user's running
production installation was neither stopped nor replaced. Physical banner
activation is user-confirmed; physical IME composition and a clean Ubuntu
26.04 installation are not covered by these checks. Earlier user-confirmed
Herdr/cross-app clipboard acceptance remains distinct from automated evidence.
`.deb`, Ubuntu 24.04 and Ghostty parity remain deferred.

### Acceptance CI ordering correction — 2026-10-22

The next documentation head (`d859550`) passed macOS CI but failed Linux's
`test_poll_started_before_stop_cannot_publish_pre_stop_state`. The fixture
released its captured Running observation after a fixed 0.6 seconds, whether
or not the test's stop command had completed. A delayed-caller reproduction
failed against the unchanged installed backend and showed the poll response
already buffered before stop completion; this is not evidence of a stale
snapshot arriving after a completed stop. Thirty unmodified local repetitions
passed, consistent with a scheduling-dependent test failure.

Replace the fixture timing assumption with a bounded explicit hold, released
only after stop acknowledgment; cleanup releases it on assertion failure.
The delayed-caller reproduction then passed (1.829s), and all 54 affected
backend integration tests passed (27.621s). Evidence:
`.tmp/stale-poll-delayed-caller-red.log`,
`.tmp/stale-poll-delayed-caller-green.log`, and
`.tmp/stale-poll-backend-suite-green.log`. No production Swift code or bundled
binary changed. Current-head CI must be verified after publication.

### Ratings

Pxx identifiers are stable and separate from historical Fxx identifiers. P06's final rating of 9 supersedes its earlier rating of 8.

| ID | Feature | Importance / 10 | Milestone |
| --- | --- | --- | --- |
| P01 | Start/stop DevPods | 10 | M01 |
| P02 | Workspace lifecycle notifications | 10 | M01 |
| P03 | Connect/disconnect/reload SSH and recovery | 7 | M04; readiness prerequisite in M01 |
| P04 | Automatic Claude hook installation/cleanup | 10 | M01 |
| P05 | Claude notifications, badges and activation | 10 | M01 |
| P06 | Terminal text copy/paste | 9 | M02 |
| P07 | Clipboard-image upload | 8 | M03 |
| P08 | Open in Zed / authenticated ded | 8 | M03 |
| P09 | Keyboard navigation and session shortcuts | 8 | M03 |
| P10 | Friendly workspace names | 5 | M06 |
| P11 | Saved sidebar ordering | 5 | M06 |
| P12 | Hide/show workspaces | 2 | M08 |
| P13 | Multiple terminal tabs | 1 | M09 |
| P14 | Create workspaces | 1 | M10 |
| P15 | Recreate workspaces | 1 | M10 |
| P16 | In-app Guide | 1 | M10 |
| P17 | UI/input polish | 6 | M05 |
| P18 | Production .deb | 3 | M07 |

## M01 — Start/stop and DevSpace notification lifecycle

**Features:** P01, P02, P04, P05 — all 10/10.

- Add state-appropriate Start/Stop actions, busy-state disabling, operation progress and retained errors using existing commands/snapshots. Keep compact rows; do not add provisioning dialogs or tabs.
- Match macOS lifecycle notifications: distinguish confirmed Running/Stopped transitions from initial discovery and unknown/transient status. Announce becoming usable only after the owned SSH connection produces its first terminal output, not merely when Start returns.
- Detect externally initiated stops, including provider inactivity shutdown, through polling without issuing lifecycle commands. Repeated snapshots must not repeat notifications. Match macOS foreground/selected-workspace suppression and badge behavior.
- Match macOS's external-start exception: a workspace restarted outside DevSpace, with no intended app connection, announces its confirmed Running transition without opening SSH. Intended app connections still require first output, including after a failed connection awaiting explicit retry.
- Finish/verify automatic Claude hooks once per live connection and safe removal on disconnect. Preserve unrelated settings and another live channel's integration. Hook success remains implicit; failures are nonfatal and actionable.
- Finish/verify Claude finished/needs-input alerts, badges, clearing on selection and click-to-focus of the existing terminal.

Readiness and generation-safe cleanup are prerequisites here; fix defects blocking notifications/hooks, but defer additional SSH controls and recovery presentation to M04. Reuse macOS transition gating rather than inventing another notification policy.

**Acceptance:** fixture-controlled start/stop and external transitions produce the correct single event; initial/unknown states produce no false alerts; first output gates the live event; selection never starts a stopped workspace; stale integration completions cannot alter replacements; notification activation creates no duplicate terminal.

## M02 — Reliable terminal text copy/paste

**Feature:** P06 — 9/10.

- Verify and finish selection, Ctrl+Shift+C/V, ordinary text paste and bracketed paste through the active VTE terminal.
- Preserve terminal Ctrl+C/Ctrl+R and dialog text input.
- Preserve selection/scrollback across workspace switches and polling. Stale clipboard callbacks cannot target hidden or retired panes.

**Acceptance:** actual private-display clipboard round-trips, multiline/Unicode text and bracketed paste; ordinary Ctrl keys reach the shell; missing text and closed-pane callbacks fail safely. Record physical-host clipboard acceptance separately; replacing the user's physical clipboard requires authorization.

## M03 — Image paste, editor integration and keyboard navigation

**Features:** P07, P08, P09 — all 8/10.

- Finish/verify image upload into the original active pane, bounded PNG handling, local/remote temporary-file cleanup and nonfatal failures. Reuse the existing transport.
- Open in Zed targets the active terminal directory with macOS-equivalent workspace fallback. Explicit ded paths never fall back to another folder. Preserve stale-request protection and editor fallback rules with Linux executable discovery.
- Port VTE directory-URI reporting for editor targeting; tab-title presentation remains deferred to M09.
- Add Ctrl+Shift+R/O/B for reload, Zed and sidebar toggle; Ctrl+Shift+1–9 selects visible workspaces. Retain copy/paste from M02 and suppress workspace shortcuts during dialogs.

Do not add new-tab, tab-navigation or reorder shortcuts before their owning milestones. Reuse reconnect for the reload shortcut before expanding recovery UI in M04.

**Acceptance:** exact uploaded bytes and correct injection target; stale upload cannot inject into a replacement; Unicode/space-containing editor paths are correct; missing/failing Zed stays nonfatal; shortcuts do not swallow ordinary shell keys.

## M04 — Explicit SSH controls and recovery

**Feature:** P03 — 7/10; builds on M01 readiness guarantees.

- Expose Connect, Disconnect and Reload SSH Session according to macOS state/session eligibility.
- Show progress, actionable failures and explicit retry without starting stopped workspaces or adding automatic network reconnection beyond macOS.
- Keep connect idempotent: polling, selection and notification activation reuse the existing terminal.
- Reload waits for the previous master and owned cleanup before replacement. Disconnect/terminal exit never stops the DevPod.
- Verify backend failure leaves the UI responsive and shutdown releases owned resources without touching another instance.

**Acceptance:** retry, reload ordering, late callbacks, repeated connection requests and orderly shutdown; no duplicate panes, unintended DevPod start/stop or interference with production.

## M05 — Native UI and input polish

**Feature:** P17 — 6/10.

- Verify compact sizing, theme changes, scrolling, terminal expansion, focus and readable empty/error/busy states for delivered workflows.
- Exercise Wayland and X11, available input methods, resize, scrollback and mouse selection. Fix observed defects; do not build a Ghostty-like settings surface.
- Verify development/production coexistence and shutdown/relaunch. Separate programmatic evidence from physical desktop checks.

**Acceptance:** high-priority workflows work on the current Ubuntu desktop; theme/selection changes preserve terminal state; direct evidence covers input/focus/layout or explicitly documents platform limitations.

## M06 — Friendly names and saved ordering

**Features:** P10, P11 — both 5/10.

- Add the macOS-inspired friendly-name dialog and Move Up/Down context-menu actions with boundary disabling.
- Reuse existing alias/order commands and persistence; names never change DevPod IDs.
- Add Ctrl+Shift+Alt+Up/Down for reordering the selected visible workspace.

**Acceptance:** names/order survive restart; unavailable actions cannot run; organization and polling preserve selected/background terminals.

## M07 — Production package and high-priority handoff

**Feature:** P18 — 3/10. This release does not depend on M08–M10.

- Build/verify the .deb with confirmed GPL-3.0-or-later icons, runtime notices and approved Git maintainer identity.
- Verify dependencies, desktop entry, launcher, relocation and absence of repository-local toolchain requirements.
- Install/run on clean Ubuntu 26.04 without development tools and exercise installed M01–M06 workflows against an authorized DevPod.
- Run final Linux/macOS regressions, update docs and PR #111 through the stack workflow, and retain an evidence-backed checklist.
- Build production artifacts only with release approval; never install over, replace or stop production without separate permission.

**Acceptance:** installable package, verified installed-app daily workflow and current Linux/macOS CI. Low-priority conveniences do not block handoff.

## M08 — Optional hide/show organization

**Feature:** P12 — 2/10.

- Add Hide/Show and collapsible Hidden section using existing commands/layout storage.
- Match macOS selected-hidden-row behavior so active workspaces remain reachable. Hiding is not stopping or disconnecting.

**Acceptance:** persistence, collapse/expand and selected-hidden access; no lost terminal state or accidental lifecycle commands.

## M09 — Optional multiple terminal tabs

**Feature:** P13 — 1/10; not required for core usability.

- Add explicit private new_terminal command while keeping connect idempotent. Additional shells share one owned master.
- Show numbered tabs, close controls and + only for multiple panes. Preserve stable order and active-pane identity per workspace.
- Closing a tab preserves siblings; closing the last disconnects without stopping the DevPod. Background shells and scrollback survive switching/polling.
- Add Ctrl+Shift+T and Ctrl+PageUp/PageDown for creation/navigation; use M03 directory reporting for titles.

**Acceptance:** independent shell round-trips over one master, correct focus after switching/closing, stable snapshots and stale-event rejection.

## M10 — Optional provisioning conveniences and Guide

**Features:** P14, P15, P16 — all 1/10. DevPod CLI remains the alternative until this milestone.

- Add Create with repository URL/optional ID and Recreate with the macOS destructive-operation confirmation.
- Reuse backend commands for live provisioning output, cancellation, retained failure output and successful created-workspace selection.
- Reconnect only after lifecycle completion and confirmed running status. Do not add Delete UI merely because the backend supports it; current macOS UI is the reference.
- Add New/Guide access and GTK Guide covering only implemented workflows and actual bindings.

**Acceptance:** duplicate submission blocked, cancellation scoped to its operation, readable failures, SSH cleanup before recreation, no stopped workspace awakened by selection, and Guide matching shipped behavior.

## Testing and execution rules

- Swift XCTest for portable logic; native Swift GTK/VTE tests for UI/session behavior; existing packaging harnesses for artifacts. Use TDD for behavior changes.
- Run affected tests per milestone. Run broader suites for shared lifecycle/protocol changes and once for release verification—not after every documentation change.
- Validate host-facing acceptance within its owning milestone; do not postpone everything until packaging. Distinguish fixture-only and manual evidence.
- Inspect macOS source and dependencies up to depth two before changes. macOS semantics outrank earlier UI preferences; ratings determine scheduling, not replacement behavior.
- Use fixtures for create/start/stop/recreate unless a disposable real workspace is explicitly authorized. Existing wc-1 authorization covers temporary SSH/hook tests, not lifecycle mutation or project-file edits. Recheck availability before live tests.
- Preserve production and unrelated edits. Use global Swift, keep scratch evidence in .tmp, restore Package.resolved after Linux Swift commands and commit verified milestones on the feature branch.
- No renderer replacement, speculative settings surface, splits or automatic network-reconnection feature beyond macOS.
