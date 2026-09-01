# Resilient SSH Connect Design

## Goal

Make a transient DevPod stdio failure during initial SSH startup recover without
the Connecting card flickering back to an unexplained disconnected state.

## Design

DevSpace will distinguish a primary terminal that exits before connection
handoff finishes from an established terminal that later exits. A pre-ready
nonzero exit is a startup failure. DevSpace keeps the user's connection intent,
removes only the failed pane, and retries the primary connection at most twice
with delays of 0.5 and 1.5 seconds. Retry callbacks are generation-checked and
must also confirm that the workspace is still Running and the user has not
disconnected, stopped, or recreated it.

The primary PTY will be allowed to produce output before DevSpace starts the
shell-integration helper SSH call. Claude hook injection will start only after
the terminal handoff resolves. This avoids opening multiple DevPod transports
during the most fragile part of primary-session establishment. The existing
10-second fail-open deadline remains: if the primary produces no output, the
terminal is revealed without waiting for shell integration.

After two failed retries, DevSpace withdraws the active connection attempt,
leaves the running pod untouched, and records a connection failure containing
the SSH exit status. The status card shows this message beside an enabled
Connect button. A manual Connect clears the failure and begins a fresh retry
budget. An explicit Disconnect, Stop, Recreate, a definitive Stopped status, or
workspace removal cancels pending retry state and clears the failure.

Established terminal exits retain current behavior: extra tabs close; the last
terminal disconnects without automatic retry. This preserves intentional
`exit` behavior and avoids reconnecting after a real session ends.

## Interfaces

- `AppModel` exposes `connectionFailure(_:) -> String?` for the selected status
  card.
- A small injected retry scheduler makes retry timing deterministic in tests.
- No Core SSH arguments, DevPod commands, persisted data, or public package API
  changes are required.

## Testing

- A primary nonzero exit while handoff is pending schedules a retry and keeps
  the model in Connecting state.
- Retry callbacks ignored after Disconnect and after a workspace stops.
- Exactly two retries are permitted; the third failed attempt exposes the SSH
  exit status and restores the Connect action.
- Manual Connect clears the failure and receives a fresh retry budget.
- An exit after terminal reveal and an extra-tab exit never retry.
- Shell integration does not start before primary PTY output, starts once after
  output, and the timeout still reveals the terminal if no output arrives.
- Action-panel tests cover rendering the failure copy with an enabled Connect
  action; the full SwiftPM test suite remains green.

