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

## Shortcuts

Keep the documented Linux bindings and ordinary terminal Ctrl keys. Reproduce
the reported failure using real key events, with terminal and sidebar focus,
before changing routing. Existing tests invoke handlers directly and are not
evidence of native event delivery. Editable fields and modal dialogs must retain
their input. Investigate the user's failing combinations once identified;
do not replace the keyboard map or guess at a root cause.

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
