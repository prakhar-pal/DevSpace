import type { WorkspaceView } from "./api";

interface Props {
  workspace: WorkspaceView;
  onStart: (id: string) => void;
}

function stateColorClasses(state: string) {
  switch(state.toLowerCase()) {
    case 'running': return 'bg-green-500/15 text-green-400';
    case 'stopped': return 'bg-slate-400/15 text-slate-300';
    case 'busy': return 'bg-amber-500/15 text-amber-400';
    default: return 'bg-red-400/15 text-red-400';
  }
}

const FIELDS: { label: string; value: (w: WorkspaceView) => string }[] = [
  { label: "Provider", value: (w) => w.provider },
  { label: "Source", value: (w) => w.source },
  { label: "Last used", value: (w) => w.last_used },
];

export function ActionPanel({ workspace, onStart }: Props) {
  return (
    <div className="p-10 overflow-y-auto flex justify-center items-start">
      <div className="w-full max-w-[540px] bg-[#181818] border border-[#2a2a2a] rounded-xl px-7 py-6">
        <header className="flex items-center justify-between gap-3 mb-5">
          <h2 className="m-0 text-[22px] font-semibold break-all">{workspace.id}</h2>
          <span className={`flex-none text-[11px] font-semibold px-2.5 py-1 rounded-full uppercase tracking-wider ${stateColorClasses(workspace.state)}`}>
            {workspace.state}
          </span>
        </header>
        <dl className="m-0 mb-6">
          {FIELDS.map((f) => (
            <div className="grid grid-cols-[110px_1fr] gap-4 py-2.5 border-b border-[#242424] last:border-b-0" key={f.label}>
              <dt className="text-[#8a8a8a] text-[13px]">{f.label}</dt>
              <dd className="m-0 text-[#eaeaea] text-[14px] break-all">{f.value(workspace) || "—"}</dd>
            </div>
          ))}
        </dl>
        <div className="flex gap-2.5">
          <button className="px-[18px] py-2 rounded-lg border border-transparent text-[13px] font-medium cursor-pointer transition-colors duration-100 bg-blue-500 text-white hover:bg-blue-600" onClick={() => onStart(workspace.id)}>
            Start
          </button>
        </div>
      </div>
    </div>
  );
}
