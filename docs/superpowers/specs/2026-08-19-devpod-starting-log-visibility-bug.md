# DevPod start progress is invisible

## Reported behavior

When starting a DevPod workspace from DevSpace, neither the live `devpod up`
progress output nor the `Starting <workspace>…` header appears in the main
pane.  The workspace can still start successfully.

## Confirmed root cause

This is a UI visibility regression, not a failure to start DevPod or to create
the terminal PTY.

`AppModel.start(_:)` creates a `TerminalPaneModel` for:

```text
devpod up --ide none -- <workspace-id>
```

and marks that workspace as `starting`.  Runtime logs confirm that the PTY is
then started (for example, `pty start devpod up --ide none -- wc-8`).

`ContentView.MainPane` mounts every pane through `paneContainer(pid:)`, but
applies this visibility predicate to the *whole* container:

```swift
.opacity(pid == model.selectedID && model.isTerminalVisible(pid) ? 1 : 0)
.allowsHitTesting(pid == model.selectedID && model.isTerminalVisible(pid))
```

`paneContainer(pid:)` contains both the lifecycle header and the terminal:

```swift
switch model.phase(of: pid) {
case .starting:
    logHeader("Starting \(model.name(pid))…")
case .shuttingDown:
    logHeader("Stopping \(model.name(pid))…")
// …
}

TerminalPaneView(...)
```

During `.starting`, no SSH connection has been established yet, so the
workspace is not in `opened`.  `isTerminalVisible(pid)` consequently returns
false.  The start pane is mounted and running, but its entire container has
opacity zero—including the header and terminal output.

The same predicate likely hides stop-progress output during `.shuttingDown`.

## Relevant code

- `Sources/App/AppModel.swift`
  - `start(_:)` sets `starting`, creates the `devpod up` terminal pane, and
    installs `onUpFinished`.
  - `isTerminalVisible(_:)` is intentionally about an established SSH terminal
    and its shell-integration handoff, rather than lifecycle command output.
- `Sources/App/ContentView.swift`
  - `MainPane` applies the SSH-specific `isTerminalVisible` condition to the
    complete `paneContainer`.
  - `paneContainer` renders lifecycle headers and terminal output together.

## Why the existing condition exists

The opacity behavior was introduced for the SSH shell-integration handoff: it
keeps a connected SSH terminal mounted but hidden while that terminal is not
yet ready to be shown.  That behavior should remain for connected SSH panes;
it must not be used to hide lifecycle (`starting` / `shuttingDown`) panes.

## Proposed implementation direction

Introduce a display-visibility decision that distinguishes lifecycle phases
from the SSH-terminal handoff state.  For the selected workspace:

- Show the full pane container while phase is `.starting` or `.shuttingDown`,
  so the header and live DevPod output are visible.
- Preserve the existing hidden behavior only for a connected SSH pane whose
  terminal is deliberately withheld by shell integration.
- Keep non-selected workspace panes hidden, preserving the existing pane
  retention behavior.

A small AppModel helper (for example, `isPaneDisplayVisible(_:)`) is preferable
to embedding phase rules in SwiftUI, because it can be unit-tested directly.
The input/hit-testing policy should be decided during implementation: lifecycle
output needs to be visible, while allowing interaction is optional (it may be
useful for Ctrl-C).

## Test coverage to add

Add focused tests proving that, for the selected workspace:

1. `.starting` is display-visible even before an SSH terminal is considered
   visible.
2. `.shuttingDown` is likewise display-visible.
3. A connected terminal still follows the existing shell-integration handoff
   visibility rule.
4. Non-selected panes remain hidden.

Run at least the focused App/UI-state tests and `make test`.  A dev-build
manual check should start a workspace and confirm both the `Starting…` header
and streamed `devpod up` output are visible, without quitting the release app.

## Scope and cautions

- This is independent of the DevPod SSH forwarded-port collision fix merged in
  PR #93.
- Do not change the outer `devpod up` invocation or its completion lifecycle;
  the command already runs.
- The current checkout is `main`; create a feature branch before implementation
  and do not commit directly to `main`.
