import { render, screen, fireEvent } from "@testing-library/react";
import { ActionPanel } from "./ActionPanel";
import type { WorkspaceView } from "./api";

const ws: WorkspaceView = {
  id: "wc-1",
  provider: "kubernetes",
  source: "git@github.com:talview/webclients.git",
  last_used: "2026-06-13T07:25:01Z",
  state: "Stopped",
  error: null,
};

test("Start button calls onStart with id", () => {
  const onStart = vi.fn();
  render(<ActionPanel workspace={ws} onStart={onStart} />);
  fireEvent.click(screen.getByRole("button", { name: /start/i }));
  expect(onStart).toHaveBeenCalledWith("wc-1");
});

test("shows source metadata", () => {
  render(<ActionPanel workspace={ws} onStart={() => {}} />);
  expect(screen.getByText(/talview\/webclients/)).toBeInTheDocument();
});
