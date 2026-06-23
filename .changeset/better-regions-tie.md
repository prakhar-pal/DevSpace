---
"dev-space": patch
---

### 1. GUI Launch  PATH  Fixes

•  src-tauri/src/path_env.rs :
    • Interactive Shell Hang Fix: Changed the login shell invocation flags from interactive ( -ilc ) to non-interactive ( -lc ). This prevents the
    application startup from hanging on custom terminal prompts/themes (e.g. Oh My Zsh) when spawned headlessly by macOS LaunchServices.
    • Robust Path Fallbacks: Added standard installation paths ( /opt/homebrew/bin ,  /usr/local/bin , and  ~/.local/bin ) directly to the repaired  PATH
    environment variable as a fallback, ensuring  devpod  is discoverable.


### 2. Session Registry & Security Hardening

•  src-tauri/src/pty.rs  &  src-tauri/src/lib.rs :
    • Pointer-Based Session Identification: Created a new method  close_only_if_matches  in the backend  SessionRegistry  that compares raw memory
    pointers ( Arc::ptr_eq ) of active PTY sessions.
    • Reload Race Condition Resolution: Modified the reader thread exit callback to carry a clone of the specific  Session  Arc. The callback will now
    only remove the session and emit the  pty-closed  event to the frontend if the closing session matches the currently active registry session. This
    prevents the asynchronous teardown of an old session from killing a newly connected reload session.
    •  TERM  Input Sanitization: Added a  get_sanitized_term()  helper that sanitizes the user's  TERM  environment variable (allowing only alphanumeric
    characters, dashes, and underscores) to mitigate SSH argument injection risks.


### 3. Frontend Terminal State & Reconnect Logic

•  src/Terminal.tsx :
    • Added  setDisconnected(false)  to the terminal initialization block to ensure stale disconnect screens are cleared immediately when the reload
    action runs.
•  src/App.tsx :
    • Removed the  reloadingRef  state and its fragile 1-second timeout checks in  reload()  and  onExited  functions. Since the backend pointer check
    prevents explicitly closed PTY sessions from firing stale close events to new components, these frontend timeout workarounds are no longer necessary.


### 4. Test Selector Fixes

•  src/Sidebar.tsx :
    • Added the  ws-row  class name back onto both visible and hidden row containers in the workspace sidebar. This fixes the Vitest querying selection
    selectors ( closest(".ws-row") ) and allows the frontend test suite to pass cleanly.
