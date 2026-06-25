import { useEffect } from "react";

interface Props {
  onClose: () => void;
}

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="inline-block px-[6px] py-[1px] rounded border border-[#3a3a3a] bg-[#111] text-[#ddd] text-[11px] font-sans leading-[1.4] align-middle">
      {children}
    </kbd>
  );
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section className="mb-5 last:mb-0">
      <h4 className="m-0 mb-2 text-[12px] uppercase tracking-wider font-semibold text-[#8a8a8a]">
        {title}
      </h4>
      <div className="text-[13px] leading-relaxed text-[#cfcfcf] space-y-1.5">
        {children}
      </div>
    </section>
  );
}

/** A labelled how-to row: action on the left, plain-language explanation. */
function Row({ how, children }: { how: React.ReactNode; children: React.ReactNode }) {
  return (
    <div className="flex gap-3">
      <div className="flex-none w-[124px] text-[#9a9a9a]">{how}</div>
      <div className="flex-1 min-w-0">{children}</div>
    </div>
  );
}

export function GuideModal({ onClose }: Props) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div
      className="fixed inset-0 z-[1001] flex items-center justify-center bg-black/55"
      onClick={onClose}
    >
      <div
        className="w-[560px] max-w-[92vw] max-h-[85vh] flex flex-col bg-[#1d1d1d] border border-[#333] rounded-xl text-[#eee] shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between px-[22px] py-[18px] border-b border-[#2a2a2a]">
          <div>
            <h3 className="m-0 text-base font-semibold">Using DevSpace</h3>
            <p className="m-0 mt-0.5 text-[#888] text-xs">
              Manage your DevPod workspaces from one window.
            </p>
          </div>
          <button
            type="button"
            className="flex-none w-7 h-7 flex items-center justify-center rounded-md border-none bg-transparent text-[#9a9a9a] cursor-pointer hover:bg-white/10 hover:text-white transition-colors"
            aria-label="Close guide"
            onClick={onClose}
          >
            <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinecap="round">
              <line x1="3.5" y1="3.5" x2="12.5" y2="12.5" />
              <line x1="12.5" y1="3.5" x2="3.5" y2="12.5" />
            </svg>
          </button>
        </div>

        <div className="overflow-y-auto px-[22px] py-5">
          <Section title="Keyboard shortcuts">
            <Row how={<Kbd>⌘1</Kbd>}>…<Kbd>⌘9</Kbd> jump to the Nth visible workspace.</Row>
            <Row how={<Kbd>⌘B</Kbd>}>Toggle the sidebar to give the terminal more room.</Row>
            <Row how={<Kbd>Esc</Kbd>}>Close this guide.</Row>
          </Section>

          <Section title="Workspaces">
            <Row how="Sidebar list">
              Every DevPod workspace shows in the left sidebar. The colored dot is
              its status — <span className="text-green-400">green</span> running,{" "}
              <span className="text-[#9a9a9a]">grey</span> stopped,{" "}
              <span className="text-amber-400">amber</span> busy. Status refreshes
              automatically every few seconds.
            </Row>
            <Row how="Select">
              Click a workspace to open it. Stopped pods show a details panel;
              running pods drop you straight into a terminal.
            </Row>
            <Row how="Blue dot">
              A blue dot means Claude Code in that pod posted a notification.
              Selecting the workspace clears it.
            </Row>
          </Section>

          <Section title="Start & stop">
            <Row how="Start">
              Select a stopped workspace and press <strong>Start</strong>. The live{" "}
              <code className="text-[#bbb]">devpod up</code> log streams in until
              it's ready, then the terminal opens.
            </Row>
            <Row how="Stop">
              Hover a running workspace and click the ⬛ stop button, or just type{" "}
              <code className="text-[#bbb]">exit</code> in its terminal — DevSpace
              stops the pod for you.
            </Row>
          </Section>

          <Section title="The terminal">
            <Row how="Auto-connect">
              Running workspaces SSH in automatically. If the connection drops,
              DevSpace reconnects when your network returns, or use the reconnect
              button.
            </Row>
            <Row how="Copy / paste">
              <Kbd>⌘C</Kbd> copies the selection, <Kbd>⌘V</Kbd> pastes. URLs are
              clickable with <Kbd>⌘</Kbd>+click.
            </Row>
            <Row how="Newline">
              <Kbd>⇧ Enter</Kbd> inserts a newline without sending (handy for
              multi-line prompts).
            </Row>
            <Row how="Reload session">
              Right-click a running workspace → <strong>Reload SSH Session</strong>{" "}
              to reconnect the shell without restarting the pod.
            </Row>
          </Section>

          <Section title="Organize the sidebar">
            <Row how="Reorder">Drag workspaces up or down — the order is saved.</Row>
            <Row how="Rename">
              Right-click → <strong>Set friendly name…</strong> to give a pod a
              readable label. The real ID is untouched.
            </Row>
            <Row how="Hide / show">
              Right-click → <strong>Hide</strong> to tuck a workspace into the
              Hidden section at the bottom; <strong>Show</strong> brings it back.
            </Row>
            <Row how="Open in Zed">
              Right-click → <strong>Open in Zed</strong> to launch the Zed editor
              inside the workspace.
            </Row>
          </Section>

          <Section title="Claude Code notifications">
            <Row how="Automatic">
              When you open a workspace, DevSpace wires up Claude Code hooks over a
              reverse SSH tunnel. You'll get a macOS notification (or a dock bounce
              + blue dot) when Claude finishes or needs your input.
            </Row>
            <Row how="Manual test">
              Run <code className="text-[#bbb]">~/.devspace-notify</code> inside a
              pod's terminal to fire a test notification.
            </Row>
          </Section>
        </div>
      </div>
    </div>
  );
}
