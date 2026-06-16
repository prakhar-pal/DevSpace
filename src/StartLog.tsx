import { useEffect, useRef, useState } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { onPtyOutput, onPtyClosed } from "./api";

const FONT_FAMILY =
  '"FiraCode Nerd Font Mono", "Hack Nerd Font Mono", "JetBrainsMono Nerd Font Mono", "MesloLGS NF", "Symbols Nerd Font Mono", Menlo, Monaco, monospace';

// Read-only view that streams a workspace's `devpod up` startup log. The session
// is spawned by start_workspace; this only attaches to the output, so it never
// races connect_pty. Also reused for the shutdown log view after the SSH session
// ends (pass a custom `label` to override the header text).
export function StartLog({
  podId,
  onFinished,
  label,
}: {
  podId: string;
  onFinished?: () => void;
  label?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [done, setDone] = useState(false);
  const finishedRef = useRef(onFinished);
  finishedRef.current = onFinished;

  useEffect(() => {
    if (!ref.current) return;
    setDone(false);
    const term = new XTerm({
      convertEol: true,
      fontSize: 13,
      fontFamily: FONT_FAMILY,
      disableStdin: true,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(ref.current);
    fit.fit();

    let isMounted = true;
    let unlistenOutput: (() => void) | undefined;
    let unlistenClosed: (() => void) | undefined;
    (async () => {
      const out = await onPtyOutput(podId, (bytes) => term.write(new Uint8Array(bytes)));
      if (isMounted) unlistenOutput = out;
      else out();
      
      const cls = await onPtyClosed(podId, () => {
        setDone(true);
        finishedRef.current?.();
      });
      if (isMounted) unlistenClosed = cls;
      else cls();
    })();

    const onResize = () => {
      if (ref.current && ref.current.offsetParent !== null) fit.fit();
    };
    window.addEventListener("resize", onResize);

    return () => {
      isMounted = false;
      window.removeEventListener("resize", onResize);
      unlistenOutput?.();
      unlistenClosed?.();
      term.dispose();
    };
  }, [podId]);

  const headerText = label
    ? label
    : done
    ? `${podId} — startup finished`
    : `Starting ${podId}…`;

  return (
    <div className="term-pane">
      <div className="term-header">
        <span>{headerText}</span>
      </div>
      <div className="terminal-wrap">
        <div className="terminal" ref={ref} />
      </div>
    </div>
  );
}
