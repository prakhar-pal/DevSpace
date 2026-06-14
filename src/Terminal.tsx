import { useEffect, useRef, useState } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { connectPty, writePty, resizePty, onPtyOutput, onPtyClosed } from "./api";

export function Terminal({ podId, visible }: { podId: string; visible: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const termRef = useRef<XTerm | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const [disconnected, setDisconnected] = useState(false);

  useEffect(() => {
    if (!ref.current) return;
    const term = new XTerm({ convertEol: true, fontSize: 13 });
    termRef.current = term;
    const fit = new FitAddon();
    fitRef.current = fit;
    term.loadAddon(fit);
    term.open(ref.current);
    fit.fit();

    let unlistenOutput: (() => void) | undefined;
    let unlistenClosed: (() => void) | undefined;
    const enc = new TextEncoder();

    (async () => {
      unlistenOutput = await onPtyOutput(podId, (bytes) =>
        term.write(new Uint8Array(bytes))
      );
      unlistenClosed = await onPtyClosed(podId, () => setDisconnected(true));
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
      term.dispose();
      termRef.current = null;
      fitRef.current = null;
    };
  }, [podId]);

  // Re-fit and focus when this pane becomes visible: it may have been hidden
  // (display:none, zero size) while another pod was selected.
  useEffect(() => {
    if (!visible) return;
    const term = termRef.current;
    const fit = fitRef.current;
    if (!term || !fit) return;
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
