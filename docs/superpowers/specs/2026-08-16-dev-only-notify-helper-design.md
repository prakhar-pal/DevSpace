# Development-only DevSpace notification helper

## Goal

Keep Claude Code notification hooks active in both DevSpaceDev and DevSpace,
while writing the pod-side `~/.devspace-notify` manual-trigger helper only from
the development build.

## Design

Expose the existing build configuration to the Swift app target through a
compile-time conditional. `AppModel` will pass that value when it requests
hook injection. `Hooks.inject` will retain its current read/merge/write flow
for `~/.claude/settings.json` in every build, but its generated remote command
will include the helper-file write and `chmod` only when development helper
installation is enabled.

This preserves existing user Claude settings and DevSpace notification routing
in production without creating or modifying `~/.devspace-notify`. The manual
diagnostic trigger remains available in DevSpaceDev.

## Tests

Add Core coverage using a recording command runner. In both configurations it
must observe exactly one settings read followed by the merged-settings write;
the production assertion must not be satisfiable by the read command alone.
Development must also observe a command that writes and chmods
`~/.devspace-notify`; production must not include either operation.

User-facing manual-test guidance must identify `~/.devspace-notify` as a
DevSpaceDev-only helper. The in-app Guide must omit that instruction from
release builds. CI must compile the release executable so the `#if DEBUG`
production wiring is checked without assembling or launching a release bundle.

## Constraints

The decision must be compile-time, not inferred from display name, bundle ID,
or an environment variable. Hook injection remains asynchronous and
best-effort; no release build or running production app is needed for
verification.
