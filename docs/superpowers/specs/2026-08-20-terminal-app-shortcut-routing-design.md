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

Extract the event classification and action dispatch currently in
`AppModel.handleKey(_:)` into one shared AppModel routing operation.  It will
accept the `NSEvent` and report whether DevSpace consumed it.

- The local key monitor continues to call the shared router.  If consumed, it
  returns `nil`; otherwise, it returns the original event.
- `DevSpaceTerminalView` calls the same router through
  `handleTerminalKeyEquivalent(_:)`.  If consumed, it returns `true` before
  calling libghostty; otherwise it delegates to `super` unchanged.
- The router retains all current guards and semantics: modals own their
  keyboard; reload/new-tab/image paste require a visible terminal; Cmd+O
  requires a running workspace; unowned keys pass through.
- Cmd+B no longer has a special routing path.  It follows the same shared
  dispatcher as Cmd+O, Cmd+R, Cmd+T, Cmd+V, Cmd+1–9, Cmd+Shift+T, and
  Cmd+Option+Up/Down.

This is intentionally limited to shortcuts DevSpace already owns.  It does
not change libghostty key handling for unowned terminal/application shortcuts.

## Error and state handling

The dispatcher consumes an owned shortcut even when its action is inapplicable
(for example Cmd+R without an active visible terminal), matching existing
behavior and preventing command bytes from reaching the pod.  A modal leaves
the event unconsumed so its native controls retain ownership.

## Verification

Add real-surface tests in Kitty keyboard mode that establish both sides of the
boundary:

1. Cmd+O and Cmd+R call the terminal-level handler and are consumed before
   libghostty writes Kitty bytes.
2. A non-owned command shortcut still reaches libghostty.
3. The pure shared classifier/dispatcher continues to recognize all existing
   DevSpace shortcut families and keeps modal/terminal-state guards unchanged.

Run focused shortcut and terminal-key-equivalent tests, then `make test`.

## Non-goals

- Add new shortcuts.
- Change the actions associated with current shortcuts.
- Modify Ghostty, PTY, SSH, DevPod, or notification behavior.
