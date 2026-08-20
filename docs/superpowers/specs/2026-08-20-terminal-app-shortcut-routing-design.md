# Terminal App-Shortcut Routing Design

## Goal

Make all existing DevSpace-owned keyboard shortcuts work while an embedded
libghostty terminal is first responder.  The terminal must not receive those
shortcuts as Kitty keyboard bytes.

## Problem

The local AppKit key monitor normally calls `AppModel.handleKey(_:)`, which
owns DevSpace shortcut behavior.  libghostty can instead consume a command key
equivalent in `DevSpaceTerminalView.performKeyEquivalent(with:)` before that
local monitor receives it.

The prior Cmd+B fix introduced this terminal boundary but only recognized
Cmd+B.  Cmd+O and Cmd+R—and any other DevSpace shortcut handled exclusively by
the local monitor—therefore still fall through to libghostty when a terminal
is focused.

## Design

Extract event classification from `AppModel.handleKey(_:)` into a shared,
pure `AppShortcut` route. It converts an `NSEvent` plus an immutable
`AppShortcutState` snapshot into one of: an unowned event, a handled no-op, or
one concrete semantic action. The snapshot includes the single resolved
`PastedImage?` value, and `.imagePaste` carries that value as its payload.
`AppModel` executes that semantic action exactly once.

For a focused `DevSpaceTerminalView`, the terminal boundary is the sole owner
of a syntactically possible application shortcut. The local key monitor only
checks that cheap, pasteboard-free syntax and returns such events unchanged;
it does not classify or execute them. The terminal boundary resolves one
snapshot (including `PastedImage?`), dispatches it, and returns `true` only
when its route is handled. Text Cmd+V and other unowned events consequently
fall through to libghostty.

For every other first responder, the local monitor resolves one snapshot and
is the sole classifier/executor, returning `nil` only for a handled route.
This makes the owner unambiguous even if AppKit offers one event to both
monitor and key-equivalent processing.

The route includes every command shortcut AppModel currently owns:

- DevSpace actions: Cmd+B, Cmd+O, Cmd+R, Cmd+T, image Cmd+V, Cmd+1–9,
  Cmd+Shift+T, and Cmd+Option+Up/Down.
- Existing standard application/window actions that are currently protected
  from Ghostty: Cmd+Q, Cmd+M, Cmd+H, and Cmd+W.

Unowned terminal/application shortcuts continue to delegate to libghostty.
`ContentView` must pass every focused terminal event to the model handler; the
route's own state rules, rather than an SSH-visibility wrapper, decide whether
it is handled. This preserves Cmd+Q/M/H/W for a focused lifecycle/log terminal
as well as for an SSH terminal.

## Modal precedence

Preserve the current policy explicitly:

- Cmd+Q, Cmd+M, Cmd+H, and Cmd+W remain active before modal checks.
- When rename or guide UI is open, all DevSpace actions—including Cmd+B,
  Cmd+O, Cmd+R, Cmd+T, Cmd+1–9, and movement/tab navigation—remain unowned
  so native modal controls receive them.
- Image Cmd+V remains unowned unless an image is present and a visible terminal
  can accept it, preserving text paste for libghostty.

## Error and state handling

The dispatcher consumes a recognized DevSpace command whose action is
inapplicable when current behavior already does so (for example Cmd+R without
an active visible terminal), preventing command bytes from reaching the pod.
It preserves existing conditional pass-through for text Cmd+V and an out-of-
range Cmd+number.

Execution uses a narrow, injectable semantic-action executor in tests. The
production executor invokes the existing AppModel operations; test executors
record each requested action without launching Zed, terminating the app, or
depending on AppKit global state.

## Verification

Add real-surface tests in Kitty keyboard mode that establish both sides of the
boundary:

1. A real focused Kitty-mode terminal plus the installed AppModel local monitor
   receives one dispatched Cmd+O and Cmd+R event; each records exactly one
   corresponding semantic action and produces no Kitty bytes.
2. A non-owned command shortcut and text Cmd+V still reach libghostty through
   that same AppKit delivery path.
3. The pure classifier covers every listed shortcut family, including
   Cmd+Q/M/H/W, and locks the documented modal and inapplicable-action policy.
4. Image Cmd+V resolves its pasteboard payload once at its owning boundary and
   delivers the same payload to its recording executor.

Run focused shortcut and terminal-key-equivalent tests, then `make test`.

## Non-goals

- Add new shortcuts.
- Change the actions associated with current shortcuts.
- Modify Ghostty, PTY, SSH, DevPod, or notification behavior.
