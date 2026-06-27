import SwiftUI
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
    // Single source of focus truth: the pod id whose terminal owns the keyboard.
    @FocusState private var focusedPane: String?

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
        // selection changes or a pane is (re)created. Deferred a runloop tick so
        // the surface is in the window before we make it first responder.
        .onChange(of: model.selectedID) { scheduleFocus() }
        .onChange(of: Set(model.panes.keys)) { scheduleFocus() }
        .onAppear { scheduleFocus() }
    }

    private func scheduleFocus() {
        DispatchQueue.main.async {
            if let sel = model.selectedID, model.panes[sel] != nil {
                focusedPane = sel
            }
        }
    }

    @ViewBuilder private func paneContainer(pid: String, pane: TerminalPaneModel) -> some View {
        VStack(spacing: 0) {
            switch model.phase(of: pid) {
            case .starting: logHeader("Starting \(model.name(pid))…")
            case .shuttingDown: logHeader("\(model.name(pid)) — shutting down…")
            default: EmptyView()
            }
            TerminalPaneView(model: pane, focusID: pid, focused: $focusedPane)
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
