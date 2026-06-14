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
    <div className="modal-overlay" onClick={onCancel}>
      <form
        className="modal"
        onClick={(e) => e.stopPropagation()}
        onSubmit={(e) => {
          e.preventDefault();
          onSubmit(name.trim());
        }}
      >
        <h3>Set friendly name</h3>
        <p className="modal-sub">
          Workspace <code>{workspaceId}</code>
        </p>
        <input
          className="modal-input"
          value={name}
          autoFocus
          aria-label="Friendly name"
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") onCancel();
          }}
        />
        <div className="modal-actions">
          <button type="button" className="btn" onClick={onCancel}>
            Cancel
          </button>
          <button type="submit" className="btn btn-primary">
            Set friendly name
          </button>
        </div>
      </form>
    </div>
  );
}
