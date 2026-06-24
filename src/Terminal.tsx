import { useEffect, useRef, useState } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { ClipboardAddon, Base64, type IClipboardProvider } from "@xterm/addon-clipboard";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  writeText as clipboardWriteText,
} from "@tauri-apps/plugin-clipboard-manager";
import { openUrl } from "@tauri-apps/plugin-opener";
import "@xterm/xterm/css/xterm.css";
import { connectPty, writePty, resizePty, onPtyOutput, onPtyClosed } from "./api";

// Prefer a monospaced Nerd Font so Powerline/Nerd Font prompt glyphs (folder,
// git branch, etc. — all in the Unicode Private Use Area) render instead of
// tofu boxes. Falls back to plain monospace if none are installed.
const FONT_FAMILY =
  '"FiraCode Nerd Font Mono", "Hack Nerd Font Mono", "JetBrainsMono Nerd Font Mono", "MesloLGS NF", "Symbols Nerd Font Mono", Menlo, Monaco, monospace';

// A modern dark palette (Hyper "Snazzy") with the background matched to the
// app's #111 so the terminal blends into the surrounding chrome.
const THEME = {
  background: "#111111",
  foreground: "#e6e6e6",
  cursor: "#e6e6e6",
  cursorAccent: "#111111",
  selectionBackground: "#3b4d66",
  black: "#1e1e1e",
  red: "#ff5c57",
  green: "#5af78e",
  yellow: "#f3f99d",
  blue: "#57c7ff",
  magenta: "#ff6ac1",
  cyan: "#9aedfe",
  white: "#f1f1f0",
  brightBlack: "#686868",
  brightRed: "#ff5c57",
  brightGreen: "#5af78e",
  brightYellow: "#f3f99d",
  brightBlue: "#57c7ff",
  brightMagenta: "#ff6ac1",
  brightCyan: "#9aedfe",
  brightWhite: "#ffffff",
};

// Route xterm's OSC 52 clipboard WRITES (used by tmux `set-clipboard`, neovim's
// osc52 provider, etc.) through Tauri's clipboard plugin. `navigator.clipboard`
// is unreliable in a WKWebView for script-initiated (non-gesture) writes; the
// Rust-backed plugin has no such restriction. The addon hands us already-decoded
// text, so we just forward it.
//
// readText returns "" on purpose: answering OSC 52 read requests (`OSC 52;c;?`)
// would let any program in the pod exfiltrate the host clipboard by having it
// echoed back into the PTY. Host-initiated paste (Cmd+V) reads the clipboard
// directly, so disabling the OSC 52 read path costs us nothing.
const tauriClipboard: IClipboardProvider = {
  readText: () => "",
  writeText: (_selection, text) => clipboardWriteText(text).catch(() => {}),
};

export function Terminal({
  podId,
  visible,
  reloadNonce,
  onExited,
}: {
  podId: string;
  visible: boolean;
  reloadNonce?: number;
  onExited?: (success: boolean) => void;
}) {
  const [connecting, setConnecting] = useState(true);
  const [disconnected, setDisconnected] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const termRef = useRef<XTerm | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const visibleRef = useRef(visible);
  const onExitedRef = useRef(onExited);
  onExitedRef.current = onExited;

  useEffect(() => {
    visibleRef.current = visible;
  }, [visible]);

  useEffect(() => {
    if (!ref.current) return;
    setConnecting(true);
    setDisconnected(false);
    const term = new XTerm({
      // NOTE: no convertEol — this is a real PTY (ssh -tt); the remote tty
      // already maps \n→\r\n. Converting again corrupts full-screen TUIs
      // (e.g. neovim's line-number gutter rendered in the wrong columns).
      fontSize: 13,
      fontFamily: FONT_FAMILY,
      cursorBlink: true,
      cursorStyle: "block",
      cursorInactiveStyle: "outline",
      scrollback: 10000,
      // Option key sends Meta (ESC prefix) so Alt-bindings in shells/neovim/tmux
      // work; allowProposedApi unlocks the Unicode 11 width handling below.
      macOptionIsMeta: true,
      macOptionClickForcesSelection: true,
      rightClickSelectsWord: true,
      allowProposedApi: true,
      theme: THEME,
    });
    termRef.current = term;

    // macOS-style copy/paste through the reliable Tauri clipboard. Returning
    // false stops xterm from also sending the keystroke to the PTY.
    term.attachCustomKeyEventHandler((e) => {
      if (e.type !== "keydown") return true;

      if (e.key === "Enter" && e.shiftKey) {
        // Send ESC + LF (\x1b\n) for Shift+Enter to trigger a newline without executing across shells and Claude Code
        writePty(podId, [27, 10]);
        return false;
      }

      // macOS native Option+Left/Right word navigation
      if (e.altKey && e.key === "ArrowLeft") {
        writePty(podId, Array.from(new TextEncoder().encode("\x1bb")));
        return false;
      }
      if (e.altKey && e.key === "ArrowRight") {
        writePty(podId, Array.from(new TextEncoder().encode("\x1bf")));
        return false;
      }

      if (!e.metaKey) return true;
      if (e.key === "c") {
        const sel = term.getSelection();
        if (sel) {
          clipboardWriteText(sel).catch(() => {});
          return false;
        }
        return true;
      }
      // Note: We intentionally do not intercept 'v' (paste). WKWebView's native
      // paste handles Cmd+V natively. Intercepting it causes double-pastes.
      return true;
    });

    const fit = new FitAddon();
    fitRef.current = fit;
    term.loadAddon(fit);
    term.loadAddon(new Unicode11Addon());
    term.unicode.activeVersion = "11";
    term.loadAddon(
      new WebLinksAddon((event, uri) => {
        event.preventDefault();
        openUrl(uri).catch(() => {});
      })
    );
    // OSC 52 → system clipboard (tmux/neovim copy).
    term.loadAddon(new ClipboardAddon(new Base64(), tauriClipboard));

    term.open(ref.current);

    // GPU-accelerated rendering (crisp text, low latency). Fall back to the DOM
    // renderer if WebGL is unavailable or its context is lost at runtime.
    try {
      const webgl = new WebglAddon();
      webgl.onContextLoss(() => webgl.dispose());
      term.loadAddon(webgl);
    } catch {
      /* WebGL unsupported — xterm uses its DOM renderer */
    }

    if (reloadNonce) {
      term.clear();
    }

    fit.fit();

    let isMounted = true;
    let unlistenOutput: (() => void) | undefined;
    let unlistenClosed: (() => void) | undefined;
    let unlistenFocus: (() => void) | undefined;
    const enc = new TextEncoder();

    (async () => {
      const out = await onPtyOutput(podId, (bytes) => {
        if (isMounted) {
          setConnecting(false);
        }
        term.write(new Uint8Array(bytes));
      });
      if (isMounted) unlistenOutput = out;
      else out();

      const cls = await onPtyClosed(podId, (success) => {
        if (!success && isMounted) {
          setDisconnected(true);
        } else {
          onExitedRef.current?.(success);
        }
      });
      if (isMounted) unlistenClosed = cls;
      else cls();

      // Forward APP-level focus to xterm so it emits DECSET 1004 focus in/out
      // (ESC[I / ESC[O). xterm only tracks its textarea's DOM focus, which does
      // NOT blur when you switch to another macOS app — so Claude Code (which
      // relies on 1004 focus events to stop/start repainting status updates)
      // will spin your CPU at 100% in the background forever unless we tell
      // the terminal that the whole app lost focus.
      const foc = await getCurrentWindow().onFocusChanged(({ payload: focused }) => {
        if (focused && termRef.current) termRef.current.focus();
        else if (!focused && termRef.current) termRef.current.blur();
      });
      if (isMounted) unlistenFocus = foc;
      else foc();

      await connectPty(podId);
      await resizePty(podId, term.rows, term.cols);
    })();

    const onData = term.onData((data) =>
      writePty(podId, Array.from(enc.encode(data)))
    );
    const onResize = term.onResize(({ rows, cols }) =>
      resizePty(podId, rows, cols)
    );
    // Don't fit while hidden (display:none => zero size); offsetParent is null then.
    const handleWindowResize = () => {
      if (ref.current && ref.current.offsetParent !== null) fit.fit();
    };
    window.addEventListener("resize", handleWindowResize);

    return () => {
      isMounted = false;
      window.removeEventListener("resize", handleWindowResize);
      onData.dispose();
      onResize.dispose();
      unlistenOutput?.();
      unlistenClosed?.();
      unlistenFocus?.();
      term.dispose();
      termRef.current = null;
      fitRef.current = null;
    };
  }, [podId, reloadNonce]);

  // Re-fit and focus when this pane becomes visible: it may have been hidden
  // (display:none, zero size) while another pod was selected. When it becomes
  // hidden, blur so xterm emits focus-out (1004) to the in-pod app.
  useEffect(() => {
    const term = termRef.current;
    const fit = fitRef.current;
    if (!term || !fit) return;
    if (!visible) {
      term.blur();
      return;
    }
    const raf = requestAnimationFrame(() => {
      try {
        fit.fit();
      } catch {
        /* container not laid out yet */
      }
      if (term.cols > 0 && term.rows > 0) {
        resizePty(podId, term.rows, term.cols).catch(() => {});
      }
      term.focus();
    });
    return () => cancelAnimationFrame(raf);
  }, [visible, podId]);

  // Auto-reconnect when the OS reports the internet connection is back online
  useEffect(() => {
    if (!disconnected) return;
    const handleOnline = () => {
      setDisconnected(false);
      setConnecting(true);
      if (termRef.current) {
        termRef.current.clear();
      }
      connectPty(podId).catch(() => {});
    };
    window.addEventListener("online", handleOnline);
    return () => window.removeEventListener("online", handleOnline);
  }, [disconnected, podId]);

  return (
    <div className="flex-1 min-h-0 relative flex">
      {connecting && !disconnected && (
        <div className="absolute inset-0 bg-[#111] flex flex-col items-center justify-center gap-4 text-[#9a9a9a] text-[13px] z-[5]">
          <span className="w-5 h-5 border-2 border-[#2a2a2a] border-t-[#3b82f6] rounded-full animate-spin" aria-label="connecting" />
          <span>Connecting to SSH session…</span>
        </div>
      )}
      {disconnected && (
        <div className="absolute inset-0 bg-[#111] flex flex-col items-center justify-center gap-4 text-[#9a9a9a] text-[13px] z-[5]">
          <span className="w-8 h-8 flex items-center justify-center text-red-400">
             <svg width="24" height="24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>
          </span>
          <span>Connection dropped</span>
          <button 
            onClick={() => {
              setDisconnected(false);
              setConnecting(true);
              if (termRef.current) {
                termRef.current.clear();
              }
              connectPty(podId).catch(() => {});
            }}
            className="px-[18px] py-2 mt-2 rounded-lg border border-transparent text-[13px] font-medium cursor-pointer transition-colors duration-100 bg-[#3f3f46] text-white hover:bg-[#52525b]"
          >
            Reconnect
          </button>
        </div>
      )}
      <div className="flex-1 min-h-0 min-w-0 p-1" ref={ref} />
    </div>
  );
}
