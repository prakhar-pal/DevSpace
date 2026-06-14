import { render, screen } from "@testing-library/react";
import { Sidebar, statusColor } from "./Sidebar";
import type { WorkspaceView } from "./api";

const ws = (over: Partial<WorkspaceView>): WorkspaceView => ({
  id: "wc-1",
  provider: "kubernetes",
  source: "git@github.com:talview/webclients.git",
  last_used: "2026-06-13T07:25:01Z",
  state: "Running",
  error: null,
  ...over,
});

test("maps state to dot color", () => {
  expect(statusColor("Running")).toBe("green");
  expect(statusColor("Stopped")).toBe("grey");
  expect(statusColor("Busy")).toBe("amber");
  expect(statusColor("Unknown")).toBe("red");
});

test("renders a row per workspace", () => {
  render(
    <Sidebar
      workspaces={[ws({ id: "wc-1" }), ws({ id: "wc-2", state: "Stopped" })]}
      selectedId={null}
      badges={{}}
      onSelect={() => {}}
    />
  );
  expect(screen.getByText("wc-1")).toBeInTheDocument();
  expect(screen.getByText("wc-2")).toBeInTheDocument();
});
