# DevPod Lifecycle Design

## Goal

Add two DevPod lifecycle actions to DevSpace:

1. Create a workspace from a mandatory repository URL and an optional DevPod ID.
2. Recreate an existing workspace with DevPod's `up --recreate` behavior.

Both actions must stream the real DevPod output inside DevSpace and preserve the
existing production/dev build separation.

## User Interface

The sidebar footer becomes one horizontal row with two equal actions:

- **New** opens the workspace creation sheet.
- **Guide** retains its current behavior.

The creation sheet contains:

- **Repository URL**, a mandatory text field.
- **DevPod ID**, an optional text field.
- **Cancel** and **Create** actions.

The Create action is disabled while the repository field is empty or another
creation operation is active. Submitting trims both values before validation.

Each visible or hidden workspace's existing ellipsis/context menu gains a
**Recreate…** item. Selecting it opens a confirmation sheet that names the
workspace and states that its existing container will be replaced. The
destructive confirmation button is labelled **Recreate**. The action is
disabled while that workspace is starting, stopping, or recreating.

Open in Zed is available only for a live workspace. DevSpace defines live for
this action as a workspace whose latest status is `Running` and which is not
currently starting, stopping, or recreating. The same policy applies at every
entry point: the sidebar menu, keyboard shortcuts, DIDE requests, and the
model-level action. This prevents a cached `Running` status from opening SSH or
starting the legacy `devpod up --ide zed` fallback while recreation replaces
the container.

## Command Construction and Validation

Creation runs the following argument-vector form without invoking a shell:

```text
devpod up --ide none [--id <id>] -- <repository-url>
```

The repository value is trimmed, must be non-empty, and is passed as one argv
element. DevPod owns validation of supported repository URL formats. This keeps
DevSpace compatible with every Git URL form DevPod supports without introducing
a second, narrower parser.

When present, the optional ID must pass the existing `Devpod.validateId` rules.
DevSpace also rejects an explicit ID already present in its workspace list. If
the field is empty, the `--id` pair is omitted and DevPod derives the workspace
ID from the repository.

Recreation runs:

```text
devpod up --recreate --ide none -- <workspace-id>
```

The existing workspace ID validation remains the defense-in-depth boundary.

## Lifecycle and Data Flow

Both operations use `TerminalPaneModel`, matching the current Start and Stop
flows so provisioning output remains visible and interactive.

Creation has one app-wide transient session because the resulting workspace ID
may not be known yet. Submitting the sheet dismisses it and presents a creation
log pane above the regular main-pane content. The model snapshots existing
workspace IDs before starting the command.

After a successful creation exit, DevSpace immediately performs one list/status
refresh rather than waiting for the normal polling interval:

- With an explicit ID, DevSpace selects that workspace when it appears.
- Without an explicit ID, DevSpace subtracts the pre-operation IDs from the
  refreshed IDs. If exactly one workspace is new, it selects that workspace.
- If discovery is ambiguous, DevSpace still applies the refreshed list but
  preserves the previous selection.

The normal lifecycle reconciliation then opens SSH for the newly discovered
running workspace.

Recreation invalidates any pending SSH connection, cancels shell-integration
handoff, closes the workspace's current panes, and streams the recreate command
in that workspace's lifecycle pane. A successful exit follows the current
Start completion path: it marks the workspace optimistically Running and opens
SSH while the next poll confirms the state.

## Failure and Concurrency Behavior

Only one creation operation may exist at a time. Independent workspaces may
continue their normal sessions while creation runs.

A non-zero create exit keeps its terminal output visible with a **Creation
failed** header and a Close action. It does not change the workspace list or
selection automatically.

The creation overlay must also remain dismissible before the process reports a
non-zero exit. While creation or post-create discovery is still active, its
header shows **Cancel**. Cancel terminates the local DevPod PTY, detaches its
exit callback before termination, clears the transient creation session, and
restores the previous workspace selection. A late process-exit callback must
not recreate failure state. Keyboard input, including Escape, remains owned by
the embedded terminal and never dismisses or cancels the operation.

PTY termination is irreversible even when it races lazy terminal startup.
`PTYSession` owns one lock-protected lifecycle state: idle, running, or
terminated. Calling `terminate()` moves idle or running sessions to terminated;
once terminated, a later resize-driven `start()` is a no-op. A running child is
still signalled and reaped exactly once.

This explicit lifecycle action is preferred over a timeout, because a valid
creation may provision for an arbitrary duration, and over parsing terminal
output, because DevPod's human-readable error text is not a stable API. The
process exit status still determines whether the retained log is labelled as a
failure; cancellation is always controlled by the user.

A non-zero recreate exit keeps that workspace's terminal output visible with a
**Recreate failed** header and a Close action. It does not mark the workspace
Running or attempt SSH. Closing the failed pane returns to the workspace's
status card using the next polled state.

Closing either failed log terminates no external workspace operation because
the DevPod process has already exited.

## Component Boundaries

- `Devpod` owns pure argument construction and existing ID validation.
- `AppModel` owns sheet/confirmation state, transient creation state, recreate
  lifecycle state, command completion, and immediate refresh/discovery.
- `SidebarView` owns the footer layout and workspace menu entries.
- `ContentView` presents creation, confirmation, and failure UI while continuing
  to use `TerminalPaneView` for logs.
- `Modals.swift` contains the creation and recreate confirmation sheets.

No new dependency or external process abstraction is required.

## Testing

Implementation follows test-first red/green cycles. Automated coverage must
include:

- Exact create arguments with and without an explicit ID.
- Exact recreate arguments.
- Empty repository rejection, invalid ID rejection, and duplicate ID rejection.
- Creation sheet state and recreate confirmation state.
- Recreate disabled-state rules during other lifecycle operations.
- Successful and failed create/recreate completion behavior.
- Cancelling an active or discovery-stalled creation clears its pane and ignores
  later completion callbacks.
- Terminating a PTY before its first start prevents the child from launching.
- Escape and other terminal input do not invoke the header's Cancel/Close action.
- Open in Zed is rejected through UI, shortcut, DIDE, and direct model paths
  unless the workspace is `Running` and outside every transient lifecycle state.
- Explicit-ID selection and derived-ID discovery after immediate refresh.
- Ambiguous discovery preserving the existing selection.
- Sidebar footer and workspace-menu action availability through extracted pure
  view-policy helpers where direct SwiftUI inspection is impractical.

Final verification uses `make test` and `make build-dev`. The production bundle
must not be built or stopped during DevPod lifecycle development.

## Out of Scope

- Selecting providers, machines, branches, devcontainer paths, or other DevPod
  creation flags.
- Creating from a local folder.
- Multiple simultaneous creation operations.
- Resetting workspace sources (`devpod up --reset`).
- Changing existing Start, Stop, Delete, or Zed behavior beyond shared lifecycle
  helpers needed by this feature.
