# DevPod SSH Port-Collision Design

## Goal

Allow DevSpace to open a terminal for a running DevPod workspace even when
another DevPod SSH session already owns the workspace's configured local
forwarded ports.

## Problem

DevSpace currently launches `ssh <pod>.devpod`. The DevPod-generated SSH host
alias invokes `devpod ssh --stdio`, which starts every `forwardPorts` service
from the workspace's devcontainer configuration. A second session attempts to
bind the same localhost ports and exits before the terminal opens.

## Design

DevSpace will invoke the supported DevPod CLI directly:

`devpod ssh --start-services=false ... <pod>`

The command builder will retain the existing reverse notification forwarding
and remote `TERM=xterm-256color` setup using DevPod's corresponding flags.
Because service forwarding is disabled only for DevSpace's process, normal
terminal and IDE connections keep their existing forwarding behavior.

## Error Handling

The existing PTY exit handling remains responsible for reporting a failed
DevPod transport. This change removes the duplicate local-port bind failure;
other DevPod connection errors remain visible in the terminal unchanged.

## Testing

Core unit tests will assert the DevPod executable and arguments, including
`--start-services=false`, reverse forwarding, terminal environment, and the
second-terminal behavior that omits the reverse tunnel. Existing SSH helper
tests remain unchanged unless their API expectations are replaced.
