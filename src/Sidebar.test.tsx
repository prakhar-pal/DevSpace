import { render, screen, fireEvent } from "@testing-library/react";
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
  expect(statusColor("Pending")).toBe("grey");
  expect(statusColor("Unknown")).toBe("red");
});

test("renders a row per workspace", () => {
  render(
    <Sidebar
      workspaces={[ws({ id: "wc-1" }), ws({ id: "wc-2", state: "Stopped" })]}
      selectedId={null}
      badges={{}}
      onSelect={() => {}}
      onStart={() => {}}
      onStop={() => {}}
    />
  );
  expect(screen.getByText("wc-1")).toBeInTheDocument();
  expect(screen.getByText("wc-2")).toBeInTheDocument();
});

test("running pod shows a Stop action, stopped pod shows Start", () => {
  const onStart = vi.fn();
  const onStop = vi.fn();
  render(
    <Sidebar
      workspaces={[ws({ id: "wc-1", state: "Running" }), ws({ id: "wc-2", state: "Stopped" })]}
      selectedId={null}
      badges={{}}
      onSelect={() => {}}
      onStart={onStart}
      onStop={onStop}
    />
  );
  fireEvent.click(screen.getByRole("button", { name: /stop wc-1/i }));
  expect(onStop).toHaveBeenCalledWith("wc-1");
  fireEvent.click(screen.getByRole("button", { name: /start wc-2/i }));
  expect(onStart).toHaveBeenCalledWith("wc-2");
});
