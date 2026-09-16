# Multiplexed SSH Terminal Tabs Design

## Problem

Each DevSpace terminal tab currently starts an independent SSH process. Only
the first process owns the reverse-notification tunnel, so closing that tab can
leave secondary tabs running without notification or folder-opening routing.
An SSH transport interruption also destroys every terminal channel.

## Goals

- Keep secondary terminal tabs usable when the first visible tab closes.
- Use one authenticated SSH transport and one reverse tunnel per workspace.
- Provide an independent shell channel for every visible terminal tab.
- Recover a disrupted transport through the existing fresh-status Fibonacci
  policy: 3, 5, 8, 13, and 21 seconds.
- After recovery, recreate the same number of fresh terminal tabs and restore
  the previously selected tab position.
- Avoid waking a stopped workspace during automatic recovery.

## Non-goals

- Resuming a lost interactive shell or the foreground processes it hosted.
- Guaranteeing process survival after a transport loss; users need `tmux`,
  `screen`, a service manager, or another remote detachment mechanism for that.
- Sharing a shell process between tabs. Tabs share a transport but each receives
  its own SSH session channel and remote shell.

## Architecture

Each connected workspace owns an app-managed, non-interactive SSH master. The
master uses the validated DevPod ProxyCommand, the build-specific environment,
and the sole reverse `-R` tunnel. It is not represented by a visible terminal
tab.

Visible tabs are SSH multiplex clients connected with the same `ControlPath`.
They create ordinary interactive session channels but do not declare `-R`.
The client arguments retain per-session terminal environment configuration.
No tab is the transport owner, so any individual tab can close without
affecting its siblings or reverse tunnel.

### Control-socket ownership

Every launched DevSpace process creates an owner-only control directory under a
short, app-specific temporary root. Its path contains the bundle channel and a
launch-unique identifier; the workspace socket name is a short hash of its ID.
Consequently, production and development builds—and simultaneous instances of
either build—can never attach to each other's master or reverse tunnel.

The transport controller writes ownership metadata beside each socket: bundle
identifier, process ID, process start time, workspace ID, and control path.
At launch it examines only directories for its own bundle channel. It may send
`ssh -O exit` and remove a directory only when the recorded owner is no longer
the matching DevSpace process. If ownership cannot be proved, it leaves the
directory intact and reports a transport-start error rather than unlinking or
attaching to an unknown socket. This cleans orphaned masters after a crash
without disrupting a live application instance.

Two live instances of the same bundle cannot own the same workspace's fixed
reverse-forward port. When ownership metadata identifies a live same-build
owner for that workspace, the later instance does not launch a master or
consume retry budget. It shows a non-retryable status-card error directing the
user to the instance that already owns the session. Development and production
remain independent because their bundle channels and reverse-forward ports are
different.

Master readiness is established only when an `ssh -O check` against the
instance's socket succeeds, not merely when the master process launches. The
socket and metadata are removed after the controller has terminated its own
master or observed its exit.

### Master controller

A dedicated `SSHTransportSession` owns the master `Process`, its output/error
pipes, the control-directory lease, a generation token, and one state:
starting, ready, stopping, or exited. It launches an eager `ssh -N` master with
`ControlMaster=yes`, `ControlPersist=no`, `ExitOnForwardFailure=yes`, and the
master-only reverse forward. A process-termination handler reports every exit
to `AppModel` on the main actor.

The controller continuously drains the master's output and error pipes on a
background queue. Standard output is discarded; standard error is retained as
a bounded tail for connection diagnostics. No pipe may remain unread long
enough to block the long-lived SSH process.

While starting, the controller polls `ssh -O check` through its exact control
path. A 15-second generation-bound readiness deadline terminates a master that
has neither become ready nor exited. Deadline expiry and a pre-ready process
exit both enter the existing initial startup retry/error policy. A post-ready
exit enters disruption recovery. Late readiness, check, and termination events
whose generation no longer matches are ignored.

## Session Lifecycle

Opening a workspace first establishes its hidden master. DevSpace opens the
initial visible client only after that master reports readiness. New Terminal
opens another client channel through the same ready master.

Closing a visible tab removes only that client. Closing the final visible tab
terminates the master, removes the workspace's auto-connect intent, and shows
the status card. Reload replaces only the active client shell through the
existing master.

On an unexpected master exit, DevSpace marks all client panes as being torn
down so their own exit callbacks cannot initiate duplicate recovery. It saves
the client-tab count and active-tab index, removes the panes, and starts the
existing disruption retry state machine. Each retry runs fresh `devpod status`;
only a Running result starts another master. A non-running result stops
recovery. Status failures consume the same five Fibonacci attempts.

When a recovered master is ready, DevSpace opens the saved number of fresh
client shells and restores the saved active index once those panes are mounted.
The old shell channels cannot resume; remote work survives only when it was
already independent of the SSH PTY.

Lifecycle actions—Disconnect, Stop, Recreate, deletion, workspace removal,
and a fresh Stopped poll—invalidate the master generation, cancel recovery,
terminate the transport, and reject late readiness or status callbacks.

## Error Handling

Master readiness includes failure to create the control directory, authenticate,
bind the reverse forward, or pass the readiness deadline.
`ExitOnForwardFailure=yes` ensures a failed tunnel bind fails the master rather
than leaving visible tabs falsely connected. These failures use the existing
recovery path only after a previously established transport; an initial
connection keeps its current startup retry behavior.

Clients do not fall back to direct SSH when the master is unavailable. They
remain unavailable until the master is ready, preserving the invariant of one
transport and one tunnel per workspace.

### Client-channel failures

Each visible terminal slot has its own client lifecycle, separate from the
master lifecycle. A user-initiated close or clean client exit removes only that
slot and leaves the master and sibling tabs intact. An unexpected nonzero exit
while the master remains ready retries only that client slot after 0.5 and 1.5
seconds; it never starts a direct SSH transport or master-wide recovery.

After those retries are exhausted, the slot becomes a visible failed-tab panel
with its error and Retry / Close actions. Retry creates a fresh client through
the existing master. If the master exits at any point, its generation supersedes
and cancels all client retries; master recovery restores the saved tab count
and selected position as described above.

## Testing

Core SSH tests cover master and client arguments, including master-only `-R`,
control socket use, and forward-failure behavior. Transport-controller tests
use injected process/check schedulers to cover readiness, the 15-second
deadline, stale generation rejection, safe orphan cleanup, same-build live
owner rejection, and bounded pipe draining. App-model tests use an injected
transport controller to cover:

- primary-tab close leaving another client and master alive;
- final-tab close terminating the master and disconnecting;
- master disruption preserving tab count and active position through recovery;
- fresh Stopped status suppressing reconnection;
- status failure consuming Fibonacci delays;
- late master/status callbacks being ignored after disconnect, stop,
  recreation, or workspace removal; and
- client-only failure retries, failed-tab presentation, and no independent
  direct SSH transport.

Integration coverage starts simultaneous development and production controllers
for the same workspace and verifies distinct control paths and reverse tunnels.
It also simulates an orphaned same-build controller and verifies that only a
proven-dead owner is terminated and cleaned up.

The full Swift test suite and a development bundle build validate the change.
