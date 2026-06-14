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

const noop = () => {};

function renderSidebar(over: Partial<React.ComponentProps<typeof Sidebar>> = {}) {
  return render(
    <Sidebar
      visible={[ws({ id: "wc-1" }), ws({ id: "wc-2", state: "Stopped" })]}
      hidden={[]}
      selectedId={null}
      badges={{}}
      starting={[]}
      onSelect={noop}
      onHide={noop}
      onUnhide={noop}
      onReorder={noop}
      {...over}
    />
  );
}

test("maps state to dot color", () => {
  expect(statusColor("Running")).toBe("green");
  expect(statusColor("Stopped")).toBe("grey");
  expect(statusColor("Busy")).toBe("amber");
  expect(statusColor("Pending")).toBe("grey");
  expect(statusColor("Unknown")).toBe("red");
});

test("renders a row per visible workspace", () => {
  renderSidebar();
  expect(screen.getByText("wc-1")).toBeInTheDocument();
  expect(screen.getByText("wc-2")).toBeInTheDocument();
});

test("sidebar has no start/stop lifecycle buttons", () => {
  renderSidebar();
  expect(screen.queryByRole("button", { name: /start|stop/i })).toBeNull();
});

test("hide action calls onHide; hidden section renders with unhide", () => {
  const onHide = vi.fn();
  const onUnhide = vi.fn();
  renderSidebar({
    visible: [ws({ id: "wc-1" })],
    hidden: [ws({ id: "wc-9", state: "Stopped" })],
    onHide,
    onUnhide,
  });
  fireEvent.click(screen.getByRole("button", { name: /hide wc-1/i }));
  expect(onHide).toHaveBeenCalledWith("wc-1");

  expect(screen.getByText(/Hidden \(1\)/)).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: /unhide wc-9/i }));
  expect(onUnhide).toHaveBeenCalledWith("wc-9");
});
