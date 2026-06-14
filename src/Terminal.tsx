import { useEffect, useRef } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { connectPty, writePty, resizePty, onPtyOutput } from "./api";

export function Terminal({ podId }: { podId: string }) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!ref.current) return;
    const term = new XTerm({ convertEol: true, fontSize: 13 });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(ref.current);
    fit.fit();

    let unlisten: (() => void) | undefined;
    const enc = new TextEncoder();

    (async () => {
      unlisten = await onPtyOutput(podId, (bytes) =>
        term.write(new Uint8Array(bytes))
      );
      await connectPty(podId);
      await resizePty(podId, term.rows, term.cols);
    })();

    const onData = term.onData((data) =>
      writePty(podId, Array.from(enc.encode(data)))
    );
    const onResize = term.onResize(({ rows, cols }) =>
      resizePty(podId, rows, cols)
    );
    const handleWindowResize = () => fit.fit();
    window.addEventListener("resize", handleWindowResize);

    return () => {
      window.removeEventListener("resize", handleWindowResize);
      onData.dispose();
      onResize.dispose();
      unlisten?.();
      term.dispose();
    };
  }, [podId]);

  return <div className="terminal" ref={ref} />;
}
