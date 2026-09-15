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
master uses a private, per-workspace `ControlPath`, the validated DevPod
ProxyCommand, the build-specific environment, and the sole reverse `-R`
tunnel. It is not represented by a visible terminal tab.

Visible tabs are SSH multiplex clients connected with the same `ControlPath`.
They create ordinary interactive session channels but do not declare `-R`.
The client arguments retain per-session terminal environment configuration.
No tab is the transport owner, so any individual tab can close without
affecting its siblings or reverse tunnel.

The control socket is created in a private app-controlled temporary directory
with a path short enough for OpenSSH's Unix-domain socket limit. The directory
is owner-only. Master readiness is established only when an `ssh -O check`
against that socket succeeds, not merely when the master process launches. The
socket is removed when its transport ends or the workspace session is
explicitly disconnected.

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

Master readiness includes failure to create the control socket, authenticate,
or bind the reverse forward. `ExitOnForwardFailure=yes` ensures a failed tunnel
bind fails the master rather than leaving visible tabs falsely connected. These
failures use the existing recovery path only after a previously established
transport; an initial connection keeps its current startup retry behavior.

Clients do not fall back to direct SSH when the master is unavailable. They
remain unavailable until the master is ready, preserving the invariant of one
transport and one tunnel per workspace.

## Testing

Core SSH tests cover master and client arguments, including master-only `-R`,
control socket use, and forward-failure behavior. App-model tests use an
injected transport controller to cover:

- primary-tab close leaving another client and master alive;
- final-tab close terminating the master and disconnecting;
- master disruption preserving tab count and active position through recovery;
- fresh Stopped status suppressing reconnection;
- status failure consuming Fibonacci delays;
- late master/status callbacks being ignored after disconnect, stop,
  recreation, or workspace removal; and
- client connection failure not creating an independent direct SSH transport.

The full Swift test suite and a development bundle build validate the change.
