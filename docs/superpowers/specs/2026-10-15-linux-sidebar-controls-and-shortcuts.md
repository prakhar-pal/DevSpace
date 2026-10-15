# Linux sidebar controls and keyboard input

## Interaction

The user approved an always-visible vertical-three-dots button at the right of
each DevPod row. It opens that row's existing menu without selecting, connecting
or starting the workspace. Right-click remains an alternate entry point. Reuse
the existing popover, actions, eligibility checks and disabled states; do not
nest an interactive button inside the workspace-selection button.

Use standard GTK button appearance for New, Guide, Stop and the new menu button,
with tooltips and keyboard focus. Keep workspace selection rows flat, retain
the selected-row highlight, status dots and existing sidebar minimum width.
This is the recommended styling adjustment for the user's report that sidebar
buttons do not look clickable; it does not add actions or change lifecycle rules.

## Shortcut inventory and recommended Linux mapping

The user requested auditing every macOS shortcut and porting it to Linux, rather
than identifying individual failing combinations. Source authority is
`Sources/App/AppModel.swift:shortcutRoute`, its dispatch/terminal boundary in
`DevSpaceTerminalSurface.swift`, the modal shortcuts in `Modals.swift`, and
`Tests/App/ShortcutTests.swift`. The root README's bracket-tab shortcuts differ
from the actual implementation: the app router and Guide use Command+Shift+T
for next tab. No macOS dependency checkout is locally available, so terminal
engine default bindings outside these application-owned actions are not claimed
audited or candidates for copying Ghostty behavior into VTE.

Recommended mapping, pending the user's modifier-policy choice:

| Action | macOS source | Linux |
| --- | --- | --- |
| Select visible workspace | Command+1–9 | Ctrl+Shift+1–9 |
| Toggle sidebar | Command+B | Ctrl+Shift+B |
| Reload SSH | Command+R | Ctrl+Shift+R |
| Open in Zed | Command+O | Ctrl+Shift+O |
| New terminal | Command+T | Ctrl+Shift+T |
| Next terminal | Command+Shift+T | Ctrl+Tab; retain Ctrl+PageDown |
| Previous terminal | Not app-router-owned | Retain Ctrl+PageUp |
| Text/image paste | Command+V | Ctrl+Shift+V |
| Copy terminal selection | Command+C, terminal engine | Ctrl+Shift+C |
| Move workspace | Command+Option+Up/Down | Ctrl+Shift+Alt+Up/Down |
| Quit application | Command+Q | Ctrl+Shift+Q |
| Minimize window | Command+M | Ctrl+Shift+M |
| Hide window, reopen on activation | Command+H | Ctrl+Shift+H |
| Close window, orderly SSH cleanup | Command+W | Ctrl+Shift+W |
| Confirm valid modal form | Return | Return |
| Cancel/close modal or Guide | Escape | Escape |

Plain Ctrl+C/V/R/B/T and shell key combinations remain terminal input. A literal
Command-to-Control translation would steal terminal keys; literal Super bindings
are an alternative but may be intercepted by the desktop. The user has been
asked to select the modifier policy. Preserve native text editing in fields;
match macOS's protected Quit/Minimize/Hide/Close handling during modals. Ineligible
recognized workspace commands must not accidentally mutate another workspace or
start a stopped pod. Quit and Close use existing orderly shutdown, not direct
process termination; hiding must allow reactivation.

Reproduce native delivery with real key events under terminal/sidebar focus,
shifted symbols and Caps Lock, not just direct handler calls. Assert commands
are invoked once, ordinary terminal keys remain usable, and modal submission and
cancellation respect eligibility. Update the Linux Guide and development docs
with the implemented mapping. Do not infer a root cause for the reported failure
until native delivery is exercised.

## Alternatives and scope

An always-visible native menu button is preferred to hover-only discovery or
custom-drawn button styling. The latter alternatives add discoverability or
theme/accessibility costs. Follow the macOS menu's actions, adapted to GTK;
do not change the backend, terminal engine or production bundle for this work.

## Verification and delivery

Native Swift GTK tests must click the menu button and assert its target without
selection/connection side effects, exercise an existing menu action, and verify
disabled controls cannot act. Check native button affordances and actual key
delivery under isolated X11; check host Wayland where feasible without touching
the physical clipboard or production instance. Run affected regressions, commit
verified changes on the current feature branch, and rebuild/open the dev bundle.
Any production rebuild requires separate approval.
