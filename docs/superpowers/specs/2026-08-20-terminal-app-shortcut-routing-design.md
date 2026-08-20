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
pure `AppShortcut` route.  It converts an `NSEvent` plus AppModel state into
one of: an unowned event, a handled no-op, or one concrete semantic action.
`AppModel` executes that semantic action exactly once.

For a focused `DevSpaceTerminalView`, the terminal boundary is the sole owner
of a recognized shortcut.  The local key monitor must return that event
unchanged so AppKit can deliver it to `performKeyEquivalent(with:)`; the
terminal boundary dispatches it and returns `true` before libghostty.  For all
other first responders, the local monitor is the sole owner and returns `nil`
after dispatch.  This prevents duplicate Cmd+O/Cmd+R actions if AppKit offers
the same event to both paths.

The route includes every command shortcut AppModel currently owns:

- DevSpace actions: Cmd+B, Cmd+O, Cmd+R, Cmd+T, image Cmd+V, Cmd+1–9,
  Cmd+Shift+T, and Cmd+Option+Up/Down.
- Existing standard application/window actions that are currently protected
  from Ghostty: Cmd+Q, Cmd+M, Cmd+H, and Cmd+W.

Unowned terminal/application shortcuts continue to delegate to libghostty.

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

Execution uses a narrow, injectable semantic-action executor in tests.  The
production executor invokes the existing AppModel operations; test executors
record each requested action without launching Zed, terminating the app, or
depending on AppKit global state.

## Verification

Add real-surface tests in Kitty keyboard mode that establish both sides of the
boundary:

1. Cmd+O and Cmd+R, delivered to a Kitty-mode terminal surface, dispatch their
   corresponding semantic actions exactly once and produce no Kitty bytes.
2. The local-monitor route defers those same terminal-focused events to the
   terminal boundary, proving there is no double execution.
3. A non-owned command shortcut and text Cmd+V still reach libghostty.
4. The pure classifier covers every listed shortcut family, including
   Cmd+Q/M/H/W, and locks the documented modal and inapplicable-action policy.

Run focused shortcut and terminal-key-equivalent tests, then `make test`.

## Non-goals

- Add new shortcuts.
- Change the actions associated with current shortcuts.
- Modify Ghostty, PTY, SSH, DevPod, or notification behavior.
