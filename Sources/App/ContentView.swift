import SwiftUI
import AppKit
import GhosttyTerminal
import DevSpaceCore

/// Stack 6: sidebar + the session main pane (ActionPanel / start log / SSH
/// terminal / shutdown log), driven by AppModel's lifecycle state machine.
struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarOpen {
                SidebarView(model: model)
                Divider()
            }
            MainPane(model: model)
        }
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear { model.installKeyMonitor() }
        .sheet(isPresented: Binding(
            get: { model.renaming != nil },
            set: { if !$0 { model.renaming = nil } }
        )) {
            if let id = model.renaming {
                RenameSheet(
                    workspaceID: id,
                    name: model.aliases[id] ?? id,
                    onSubmit: { model.setAlias(id, $0); model.renaming = nil },
                    onCancel: { model.renaming = nil }
                )
            }
        }
        .sheet(isPresented: $model.guideOpen) {
            GuideSheet { model.guideOpen = false }
        }
    }
}

private struct MainPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Color(red: 0.067, green: 0.067, blue: 0.067) // #111

            // Keep every pane mounted (only the selected one visible) so SSH
            // sessions and scrollback survive switching workspaces.
            ForEach(Array(model.panes.keys), id: \.self) { pid in
                if let pane = model.panes[pid] {
                    paneContainer(pid: pid, pane: pane)
                        .opacity(pid == model.selectedID ? 1 : 0)
                        .allowsHitTesting(pid == model.selectedID)
                        .id(ObjectIdentifier(pane))
                }
            }

            overlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Move keyboard focus to the selected workspace's terminal whenever the
        // selection changes or a pane is (re)created.
        .onChange(of: model.selectedID) { focusSelectedTerminal() }
        .onChange(of: Set(model.panes.keys)) { focusSelectedTerminal() }
        .onAppear { focusSelectedTerminal() }
    }

    /// Imperatively make the selected pane's terminal the window's first
    /// responder. The library's `.terminalFocused` binding relies on a SwiftUI
    /// `@FocusState`, but nothing anchors it with a `.focused()` modifier, so
    /// programmatic writes never propagate and `makeFirstResponder` is never
    /// driven on selection change — leaving keystrokes going to the previously
    /// focused terminal. We drive first-responder directly instead, matching the
    /// pane by its `TerminalController` identity, and retry briefly because the
    /// surface NSView may not be in the window yet right after a pane is created.
    private func focusSelectedTerminal(attempt: Int = 0) {
        guard let sel = model.selectedID, let pane = model.panes[sel] else { return }
        let controller = pane.state.controller
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
           let view = Self.terminalView(in: window.contentView, controller: controller)
        {
            if window.firstResponder !== view { window.makeFirstResponder(view) }
            return
        }
        // View not mounted yet — retry for up to ~1s.
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Bail if the selection moved on while we were waiting.
            guard model.selectedID == sel else { return }
            focusSelectedTerminal(attempt: attempt + 1)
        }
    }

    /// Depth-first search for the `AppTerminalView` bound to `controller`.
    private static func terminalView(
        in view: NSView?, controller: TerminalController
    ) -> AppTerminalView? {
        guard let view else { return nil }
        if let term = view as? AppTerminalView, term.controller === controller { return term }
        for sub in view.subviews {
            if let found = terminalView(in: sub, controller: controller) { return found }
        }
        return nil
    }

    @ViewBuilder private func paneContainer(pid: String, pane: TerminalPaneModel) -> some View {
        VStack(spacing: 0) {
            switch model.phase(of: pid) {
            case .starting: logHeader("Starting \(model.name(pid))…")
            case .shuttingDown: logHeader("\(model.name(pid)) — shutting down…")
            default: EmptyView()
            }
            TerminalPaneView(model: pane)
        }
    }

    @ViewBuilder private var overlay: some View {
        if let sel = model.selectedID {
            if model.panes[sel] == nil, let w = model.byID[sel], w.state != "Running" {
                ActionPanelView(
                    workspace: w,
                    displayName: model.name(sel),
                    onStart: { model.start($0) }
                )
            }
        } else {
            Text("Select a workspace").foregroundStyle(.secondary)
        }
    }

    private func logHeader(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.1))
        .overlay(Divider(), alignment: .bottom)
    }
}

#Preview {
    ContentView(model: AppModel())
}
