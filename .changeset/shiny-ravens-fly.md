---
"dev-space": patch
---

fix: SSH auto-reconnect and workspace loading UI improvements

    - feat: detect SSH connection drops and pass exit status to frontend
    - feat: add "Disconnected" UI overlay with manual reconnect button
    - feat: auto-reconnect SSH terminal when OS regains internet connection
    - fix: set SSH ServerAliveInterval to drop hung connections reliably
    - refactor: rename "Pending" workspace state to "Loading"
    - feat: add animated loading spinners to Loading workspaces in sidebar and action

panel - fix: render Loading state pill with neutral grey instead of red error color - fix: hide "Start" button while workspace status is Loading - style: reduce font size of sidebar dropdown menu items to 13px - revert: remove experimental scroll-wheel terminal rendering hacks - docs: update CLAUDE.md to require .tmp/ for scratchpad scripts
