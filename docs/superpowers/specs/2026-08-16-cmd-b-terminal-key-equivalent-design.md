# Cmd+B terminal key-equivalent interception

## Goal

Pressing Command-B while a DevSpace terminal is focused must toggle the
DevSpace sidebar exactly once and must never write keyboard bytes to the
terminal PTY, including while a remote application such as Herdr has enabled
Kitty enhanced keyboard reporting.

## Root cause

DevSpace currently owns Command-B through an `NSEvent` local key-down monitor.
The focused libghostty `AppTerminalView` also participates in AppKit key-
equivalent dispatch through `performKeyEquivalent(with:)`. In a legacy shell,
libghostty rejects the command-modified printable key and the duplicate route
is invisible. After Herdr emits `ESC[>7u`, libghostty accepts the same event and
serializes it as `ESC[98;9u`, which the in-memory terminal session writes to the
SSH PTY.

The existing regression test covers only case-insensitive matching of the
character `b`; it does not exercise the `AppTerminalView` key-equivalent
boundary.

## Design

### App-owned terminal view

Replace the package's high-level `TerminalSurfaceView` at the DevSpace call
site with a behavior-compatible app-owned SwiftUI/`NSViewRepresentable`
wrapper. The representable creates a `DevSpaceTerminalView`, an
`AppTerminalView` subclass, and wires the same public `delegate`, `controller`,
and `configuration` properties used by libghostty's internal representable.
It also preserves color-scheme adoption on appearance and changes.

`DevSpaceTerminalView` receives a handler closure and overrides
`performKeyEquivalent(with:)`. When the handler owns the event, it performs the
sidebar action and the override returns `true` without calling `super`;
libghostty therefore cannot encode or write the key. Every other event is
delegated unchanged to libghostty.

The wrapper remains discoverable by the existing first-responder traversal
because it is an `AppTerminalView` subclass.

### Shortcut ownership

The sidebar shortcut classifier accepts only `charactersIgnoringModifiers`
equal to `b`, case-insensitively, with exactly the Command modifier among
Command, Control, Option, and Shift. `AppModel` exposes a terminal key-
equivalent handler that performs the action only when the shortcut is enabled,
preserving the current modal rule: rename and guide UI retain keyboard
ownership.

When an app-owned terminal is the first responder, the existing local monitor
recognizes Command-B but returns the event unchanged so the terminal boundary
becomes the sole action owner. With any other first responder, the local
monitor retains its current behavior: toggle the sidebar and consume the
event. This explicit routing avoids assuming whether AppKit invokes the local
monitor or `performKeyEquivalent(with:)` first, and returning `true` on the
first terminal-view invocation prevents libghostty's same-event re-entry.

`MainPane` passes the model handler into every `TerminalPaneView`, which passes
it into the app-owned terminal surface. Because the closure reads and mutates
the model when invoked, modal state changes do not require recreating terminal
surfaces.

## Alternatives considered

1. **App-owned subclass and representable (selected).** Keeps the fix local,
   uses libghostty's public surface APIs, is directly testable, and does not
   modify generated package checkout files.
2. **Fork or patch libghostty with a public key filter.** This would be a good
   upstream API but adds dependency ownership and release coordination for a
   one-shortcut integration defect.
3. **Runtime-swizzle `performKeyEquivalent(with:)`.** This can intercept the
   existing instance without replacing the representable, but it is global,
   brittle across package updates, and harder to verify. It is not justified
   when `AppTerminalView` is explicitly open for subclassing.

## Failure behavior and compatibility

- Command-B with a focused terminal and no modal toggles at the terminal
  boundary and never reaches libghostty.
- Command-B with a non-terminal first responder continues to toggle and
  consume in the local monitor.
- Command-B while rename or guide UI owns the keyboard is not intercepted by
  the terminal filter, matching the existing local-monitor behavior.
- Command-Shift-B, Control-B, Option-B, plain B, and unrelated Command keys are
  delegated to libghostty unchanged.
- Controller/configuration updates and terminal focus continue through the
  same public libghostty objects. Assigning an equivalent configuration is
  safe because libghostty's coordinator already ignores equivalent updates.
- No dependency revision, release configuration, PTY normalization, SSH, or
  Herdr-specific code changes are required.

## Testing and validation

Add app-target tests that construct real `NSEvent` key events and call the
actual `DevSpaceTerminalView.performKeyEquivalent(with:)` override. Tests must
show that exact Command-B is consumed before `super`, uppercase input is
accepted, extra or missing modifiers are rejected, and an unowned key falls
through to libghostty.

Run the focused app tests and the full SwiftPM test suite. Then build and launch
only `DevSpaceDev.app` and validate against a running DevPod: start Herdr,
press Command-B, confirm one sidebar toggle, and confirm Herdr receives no
Command-B input. The release bundle must not be built, stopped, or replaced.

## Success criteria

- Command-B toggles the sidebar exactly once with the terminal focused.
- Herdr receives no `ESC[98;9u` or corresponding Command-B action.
- Legacy shells and all non-owned terminal key equivalents retain their
  current behavior.
- Focus switching, terminal rendering, resize handling, and color-scheme
  updates continue to work.
- Focused and complete test suites pass, followed by live DevSpaceDev/Herdr
  validation.
