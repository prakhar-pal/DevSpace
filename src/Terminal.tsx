import { useEffect, useRef, useState } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { getCurrentWindow } from "@tauri-apps/api/window";
import "@xterm/xterm/css/xterm.css";
import { connectPty, writePty, resizePty, onPtyOutput, onPtyClosed } from "./api";

// Prefer a monospaced Nerd Font so Powerline/Nerd Font prompt glyphs (folder,
// git branch, etc. — all in the Unicode Private Use Area) render instead of
// tofu boxes. Falls back to plain monospace if none are installed.
const FONT_FAMILY =
  '"FiraCode Nerd Font Mono", "Hack Nerd Font Mono", "JetBrainsMono Nerd Font Mono", "MesloLGS NF", "Symbols Nerd Font Mono", Menlo, Monaco, monospace';

export function Terminal({ podId, visible }: { podId: string; visible: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const termRef = useRef<XTerm | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const visibleRef = useRef(visible);
  const [disconnected, setDisconnected] = useState(false);

  useEffect(() => {
    visibleRef.current = visible;
  }, [visible]);

  useEffect(() => {
    if (!ref.current) return;
    const term = new XTerm({ convertEol: true, fontSize: 13, fontFamily: FONT_FAMILY });
    termRef.current = term;
    const fit = new FitAddon();
    fitRef.current = fit;
    term.loadAddon(fit);
    term.open(ref.current);
    fit.fit();

    let unlistenOutput: (() => void) | undefined;
    let unlistenClosed: (() => void) | undefined;
    let unlistenFocus: (() => void) | undefined;
    const enc = new TextEncoder();

    (async () => {
      unlistenOutput = await onPtyOutput(podId, (bytes) =>
        term.write(new Uint8Array(bytes))
      );
      unlistenClosed = await onPtyClosed(podId, () => setDisconnected(true));
      // Forward APP-level focus to xterm so it emits DECSET 1004 focus in/out
      // (ESC[I / ESC[O). xterm only tracks its textarea's DOM focus, which does
      // NOT blur when you switch to another macOS app — so Claude Code (which
      // enables 1004) would otherwise never see focus-out and think it's always
      // focused. Only the visible pane re-focuses.
      unlistenFocus = await getCurrentWindow().onFocusChanged(({ payload: focused }) => {
        if (focused) {
          if (visibleRef.current) term.focus();
        } else {
          term.blur();
        }
      });
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
  }, [podId]);

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

  const reconnect = async () => {
    setDisconnected(false);
    const term = termRef.current;
    await connectPty(podId);
    if (term) await resizePty(podId, term.rows, term.cols);
  };

  return (
    <div className="terminal-wrap">
      <div className="terminal" ref={ref} />
      {disconnected && (
        <div className="term-disconnected">
          Session ended <button onClick={reconnect}>Reconnect</button>
        </div>
      )}
    </div>
  );
}
