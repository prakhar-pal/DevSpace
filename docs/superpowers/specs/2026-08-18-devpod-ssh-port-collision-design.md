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

The generated alias also supplies user-managed connection details, including
the DevPod executable path, context, remote user, and workdir. Replacing it
with a bare `devpod ssh <pod>` command is not acceptable: it may perform pod
lifecycle/setup work and can omit those alias-specific details.

## Design

DevSpace will retain `ssh <pod>.devpod` as its terminal transport. Before
starting the PTY, it will read OpenSSH's effective configuration for that alias
using `ssh -G <pod>.devpod`, obtain the resolved `proxycommand`, and append the
literal DevPod option `--start-services=false` to that command.

The existing SSH process will receive the augmented command through a command
line `-o ProxyCommand=...` override. The original alias remains the target, so
its configured user and all unrelated user SSH settings still apply. The outer
OpenSSH process continues to own DevSpace's existing `-R` notification tunnel
and `SetEnv=TERM=xterm-256color` arguments unchanged.

If effective configuration does not expose a DevPod `ssh --stdio`
`ProxyCommand`, DevSpace will not substitute a different transport or start a
workspace. It will retain the existing alias connection behavior and log the
missing safe override for diagnosis.

Only the DevSpace-owned session receives `--start-services=false`; normal
terminal and IDE sessions retain their configured service forwarding.

## Error Handling

The existing PTY exit handling remains responsible for reporting a failed SSH
transport. This change removes the duplicate local-port bind failure; other
DevPod and SSH errors remain visible in the terminal unchanged. Failure to
resolve a safe DevPod proxy override is non-destructive and does not trigger a
different connection or workspace lifecycle operation.

## Testing

Core unit tests will cover parsing and validating the effective `proxycommand`,
appending `--start-services=false` without changing its context/user/workdir,
and building the outer SSH arguments with both the override and the existing
reverse notification tunnel. They will also cover secondary terminals, which
must omit only the reverse tunnel and retain the service-forwarding override.

Manual acceptance validation observed that `make build-dev` assembled
`build/DevSpaceDev.app`. DevSpaceDev connected to `wc-2`, and running
`~/.devspace-notify Notification` in that DevSpaceDev session produced the
"Claude needs your input" notification.
