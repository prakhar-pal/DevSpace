import { useState } from "react";

interface Props {
  workspaceId: string;
  initialName: string;
  onSubmit: (name: string) => void;
  onCancel: () => void;
}

export function RenameModal({ workspaceId, initialName, onSubmit, onCancel }: Props) {
  const [name, setName] = useState(initialName);
  return (
    <div className="fixed inset-0 z-[1001] flex items-center justify-center bg-black/50" onClick={onCancel}>
      <form
        className="w-[380px] max-w-[90vw] bg-[#1d1d1d] border border-[#333] rounded-xl px-[22px] py-5 text-[#eee]"
        onClick={(e) => e.stopPropagation()}
        onSubmit={(e) => {
          e.preventDefault();
          onSubmit(name.trim());
        }}
      >
        <h3 className="m-0 mb-1 text-base">Set friendly name</h3>
        <p className="m-0 mb-[14px] text-[#888] text-xs">
          Workspace <code className="text-[#bbb]">{workspaceId}</code>
        </p>
        <input
          className="w-full box-border px-[11px] py-[9px] rounded-lg border border-[#3a3a3a] bg-[#111] text-[#eee] font-inherit focus:outline-none focus:border-blue-500"
          value={name}
          autoFocus
          aria-label="Friendly name"
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") onCancel();
          }}
        />
        <div className="flex justify-end gap-2.5 mt-[18px]">
          <button type="button" className="px-[18px] py-2 rounded-lg border border-transparent text-[13px] font-medium cursor-pointer transition-colors duration-100 hover:bg-[#2a2a2a]" onClick={onCancel}>
            Cancel
          </button>
          <button type="submit" className="px-[18px] py-2 rounded-lg border border-transparent text-[13px] font-medium cursor-pointer transition-colors duration-100 bg-blue-500 text-white hover:bg-blue-600">
            Set friendly name
          </button>
        </div>
      </form>
    </div>
  );
}
