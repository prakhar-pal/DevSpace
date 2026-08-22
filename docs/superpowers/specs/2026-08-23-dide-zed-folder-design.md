# `dide` Remote Folder Launcher — Design Spec

## Goal

Inject a `dide` shell function into each connected DevPod so a user can open a
specific existing directory in that pod's Zed remote workspace:

```text
dide .
dide /workspace
dide /home/node/projects/my-project
dide projects/my-project
```

The function supports relative and absolute paths. The target must already be
a directory; invalid targets produce a shell error and do not contact DevSpace
or Zed.

## Transport and ownership

The primary DevSpace SSH terminal already provides a reverse tunnel from the
pod to DevSpace's loopback listener. `dide` uses a dedicated `/dide` HTTP
request over that tunnel. It does not reuse Claude notification events, so
notification parsing and user-triggered folder launches remain separate.

DevSpace injects the function into both `~/.bashrc` and `~/.zshrc` alongside
the existing OSC 7 shell integration. The generated function contains the
current pod ID, listener port, and authentication token. Re-injection replaces
the marker block, preserving the existing idempotent/self-upgrading behavior.

## Pod-side function

`dide` accepts zero or one argument; no argument is equivalent to `.`. It:

1. Rejects more than one argument with a usage error.
2. Resolves the argument using `cd -- "$target" && pwd -P`, so relative paths
   are based on the invoking shell's current directory and symlinks are
   canonicalized.
3. Prints an error and returns nonzero if the target is not an existing
   directory.
4. Encodes the canonical path safely and POSTs a JSON request to
   `http://localhost:<pod-forward-port>/dide`.
5. Reports a concise success/failure message based on the HTTP request result.

The path is transported as base64 rather than interpolated directly into JSON,
avoiding quoting and shell-injection problems for spaces or shell metacharacters.

## Desktop request handling

The listener gains a dedicated request model containing `pod_id`, `path`, and
`token`. It accepts only `POST /dide`, requires a valid token, requires a
non-empty absolute path, and rejects malformed/base64-invalid requests with a
no-content response. The listener dispatches accepted requests to AppModel on
the main actor.

AppModel verifies that the pod ID is valid and currently known, then launches
Zed using the existing remote SSH alias with the supplied path. The existing
workspace-default behavior remains unchanged for the sidebar/Cmd+O flow:

```text
openInZed(id)              -> current terminal directory or DevPod workdir
openInZed(id, workdir:path) -> exactly the requested pod directory
```

The explicit-path path must not fall back to `devpod up --ide zed` with a
different directory. If the Zed CLI is unavailable, it retains the existing
session-active activation/fallback behavior, but the requested path is used
whenever a remote URL is constructed.

## Security and failure behavior

- Authentication uses the existing per-installation token and reverse tunnel.
- Pod IDs continue to pass the existing `Devpod.validateId` rules.
- The desktop accepts only absolute paths from the helper; relative paths must
  be resolved inside the pod before transmission.
- The desktop treats the path as URL data only; it is never shell-interpolated.
- Invalid directory, malformed request, token mismatch, unknown pod, or failed
  Zed launch is logged or reported without affecting the terminal session.
- No new listener port or long-lived process is introduced.

## Testing

Core tests will cover:

- generated Bash/Zsh helper contains the marker, endpoint, pod/token values, and
  safe path encoding;
- zero-argument/default and one-argument invocation contract at the script
  level;
- request JSON/base64 parsing, malformed input, relative-path rejection,
  token mismatch, and valid authentication;
- explicit-path URL construction and preservation of spaces/reserved
  characters;
- existing `openInZed` fallback behavior remains unchanged.

The full Swift test suite must pass. No release build is required for this
source-only change.

## Alternatives considered

### Reuse `/notify`

Smaller protocol change, but it couples an interactive developer command to
Claude notification payloads and message handling. Rejected for unclear
semantics and weaker separation of concerns.

### Invoke DevPod directly from the pod

The pod cannot reliably launch the host's Zed CLI or access host process state.
It would require a second host-facing transport and duplicate authentication.
Rejected in favor of the existing reverse tunnel.
