# `ded` Helper Deprecation Design

## Problem

DevSpace injects a `dide` shell function into connected DevPods to open a
remote folder in Zed. The command is being renamed to `ded`, but existing
persistent shells and user habits require a compatibility period.

## Goals

- Make `ded` the documented and canonical injected command.
- Preserve `dide` during the migration.
- Print a deprecation notice every time `dide` is used.
- Keep argument handling, request routing, validation, exit status, and
  authenticated `/dide` payloads identical for both command names.
- Update marker-managed Bash and Zsh rc-file blocks on the next connection.

## Non-goals

- Renaming the desktop listener endpoint or its `DidePayload` type.
- Changing Zed-launch behavior, tunnel selection, or notification routing.
- Removing `dide` from shells that have not yet received a refreshed injected
  rc-file block.

## Shell Integration

The generated shell integration defines `ded()` with the current complete
implementation: it accepts zero or one path argument, resolves and encodes the
path, selects a live DevSpace tunnel, and sends the authenticated `POST /dide`
request.

It also defines a compatibility wrapper:

```sh
dide() {
  printf 'dide is deprecated; use ded instead\n' >&2
  ded "$@"
}
```

The wrapper must not inspect or transform arguments. Its return status is the
return status from `ded`, so scripts using `dide` retain their existing success
and failure semantics aside from the diagnostic on standard error.

All user-facing diagnostics emitted by the canonical implementation use the
`ded:` prefix. The listener endpoint remains `/dide` because it is an internal
wire protocol, not the shell-command name.

The existing managed shell-integration marker continues to replace the whole
injected block, so reconnecting upgrades both `.bashrc` and `.zshrc` without
leaving an older standalone `dide` definition behind. A persistent shell must
source its rc file once (or reconnect) before it sees `ded` and the wrapper.

## Testing

Core shell-integration tests will execute the generated code through both Bash
and Zsh and verify:

- `ded` sends the same canonical authenticated `/dide` request that `dide`
  sent before the rename.
- `ded` reports validation, path, encoding, unavailable-tunnel, and request
  failures with its new command prefix.
- `dide` prints the deprecation notice on every invocation, forwards its exact
  arguments to `ded`, sends the same request, and preserves `ded`'s exit
  status.
- tokenless injection still contains neither command nor the `/dide` request
  code.

The full Swift test suite and a development bundle build verify the integration.
