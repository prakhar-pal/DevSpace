import { useEffect, useRef, useState } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { onPtyOutput, onPtyClosed } from "../api";

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
  visible = true,
}: {
  podId: string;
  onFinished?: () => void;
  label?: string;
  visible?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const fitRef = useRef<FitAddon | null>(null);
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
    fitRef.current = fit;
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

  useEffect(() => {
    if (!visible || !fitRef.current) return;
    const raf = requestAnimationFrame(() => {
      try {
        fitRef.current?.fit();
      } catch {
        /* container not laid out yet */
      }
    });
    return () => cancelAnimationFrame(raf);
  }, [visible]);

  return (
    <div className="flex flex-1 min-h-0 min-w-0 flex-col">
      <div className="flex justify-between items-center px-3 py-2 border-b border-[#2a2a2a]">
        <span>{headerText}</span>
      </div>
      <div className="flex-1 min-h-0 relative flex">
        <div className="flex-1 min-h-0 min-w-0 p-1" ref={ref} />
      </div>
    </div>
  );
}
