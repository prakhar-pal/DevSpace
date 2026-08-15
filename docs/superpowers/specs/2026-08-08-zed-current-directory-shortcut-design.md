# Zed current-directory launch and tab shortcut

## Goal

Open the active terminal tab's remote working directory in Zed, and make the
next-terminal-tab shortcut Command-Shift-T while retaining Command-T for a new
terminal tab.

## Design

Each `TerminalPaneModel` already exposes the shell's current remote directory
through `TerminalViewState.workingDirectory`. The shell integration writes OSC
7 updates at each prompt, so this value tracks the active terminal tab after a
user changes directory.

`AppModel.openInZed` will accept the active tab's working directory from its
caller. It will use that directory to construct the existing `ssh://` Zed URL.
If no terminal directory has been reported yet, it will retain the current
DevPod SSH-config workdir fallback. Existing Zed CLI discovery, session
detection, activation, and legacy DevPod fallback remain unchanged.

The key monitor will map Command-Shift-T to cycling forward to the next
terminal tab. Command-T continues to create a terminal tab. The shortcut guide
will describe the new shortcut and no longer advertise bracket-based tab
cycling.

## Error handling

No reported terminal directory uses the existing configured workdir fallback.
An absent Zed CLI or failed launch keeps the current fallback behavior.

## Tests

Add a regression test covering the working-directory selection with the
configured workdir fallback, and update/add keyboard-event coverage for
Command-Shift-T without changing Command-T behavior. The complete SwiftPM test
suite verifies the change.
