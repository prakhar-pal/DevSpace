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
      aliases={{}}
      onSelect={noop}
      onHide={noop}
      onUnhide={noop}
      onRename={noop}
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

test("shows friendly name when an alias is set", () => {
  renderSidebar({ visible: [ws({ id: "wc-1" })], aliases: { "wc-1": "Frontend" } });
  expect(screen.getByText("Frontend")).toBeInTheDocument();
  expect(screen.queryByText("wc-1")).toBeNull();
});

test("right-click → Set friendly name calls onRename", () => {
  const onRename = vi.fn();
  renderSidebar({ visible: [ws({ id: "wc-1" })], onRename });
  fireEvent.contextMenu(screen.getByText("wc-1"));
  fireEvent.click(screen.getByRole("button", { name: /set friendly name/i }));
  expect(onRename).toHaveBeenCalledWith("wc-1");
});

test("right-click visible row → Hide calls onHide", () => {
  const onHide = vi.fn();
  renderSidebar({ visible: [ws({ id: "wc-1" })], onHide });
  fireEvent.contextMenu(screen.getByText("wc-1"));
  fireEvent.click(screen.getByRole("button", { name: /^hide$/i }));
  expect(onHide).toHaveBeenCalledWith("wc-1");
});

test("right-click hidden row → Show calls onUnhide", () => {
  const onUnhide = vi.fn();
  renderSidebar({
    visible: [ws({ id: "wc-1" })],
    hidden: [ws({ id: "wc-9", state: "Stopped" })],
    onUnhide,
  });
  expect(screen.getByText(/Hidden \(1\)/)).toBeInTheDocument();
  fireEvent.contextMenu(screen.getByText("wc-9"));
  fireEvent.click(screen.getByRole("button", { name: /^show$/i }));
  expect(onUnhide).toHaveBeenCalledWith("wc-9");
});
