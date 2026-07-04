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
        // Title bar shows "N · workspace" for the selection (N = its ⌘N
        // sequence number in the visible sidebar list).
        .navigationTitle(model.windowTitle)
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

            // Keep every pane of every pod mounted (only the selected pod's
            // active tab visible) so SSH sessions and scrollback survive
            // switching workspaces and tabs.
            ForEach(Array(model.panes.keys), id: \.self) { pid in
                if !(model.panes[pid] ?? []).isEmpty {
                    paneContainer(pid: pid)
                        .opacity(pid == model.selectedID ? 1 : 0)
                        .allowsHitTesting(pid == model.selectedID)
                }
            }

            overlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Move keyboard focus to the selected workspace's active terminal
        // whenever the selection, tab set, or active tab changes.
        .onChange(of: model.selectedID) { focusSelectedTerminal() }
        .onChange(of: model.panes.mapValues { $0.map(\.id) }) { focusSelectedTerminal() }
        .onChange(of: model.activePane) { focusSelectedTerminal() }
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
        guard let sel = model.selectedID, let pane = model.activeModel(sel) else { return }
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

    @ViewBuilder private func paneContainer(pid: String) -> some View {
        let panes = model.panes[pid] ?? []
        let activeID = model.activeModel(pid)?.id
        VStack(spacing: 0) {
            switch model.phase(of: pid) {
            case .starting: logHeader("Starting \(model.name(pid))…")
            case .shuttingDown: logHeader("\(model.name(pid)) — shutting down…")
            case .terminal: tabBar(pid: pid, panes: panes, activeID: activeID)
            case .none: EmptyView()
            }
            // All tabs stay mounted; only the active one is visible, so
            // background shells keep running and keep their scrollback.
            ZStack {
                ForEach(panes) { pane in
                    TerminalPaneView(model: pane)
                        .opacity(pane.id == activeID ? 1 : 0)
                        .allowsHitTesting(pane.id == activeID)
                }
            }
        }
    }

    /// Slim terminal tab strip: numbered tabs (with a close × when there's
    /// more than one) and a + that opens another shell to the same pod (⌘T).
    private func tabBar(pid: String, panes: [TerminalPaneModel], activeID: UUID?) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(panes.enumerated()), id: \.element.id) { i, pane in
                HStack(spacing: 4) {
                    Text("\(i + 1)")
                        .font(.system(size: 11, weight: pane.id == activeID ? .semibold : .regular))
                    if panes.count > 1 {
                        Button {
                            model.closeTerminal(pid, paneID: pane.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Close this terminal")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(pane.id == activeID ? Color(white: 0.27) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { model.setActivePane(pid, paneID: pane.id) }
            }
            Button {
                model.newTerminal(pid)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New terminal (⌘T)")
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(white: 0.1))
        .overlay(Divider(), alignment: .bottom)
    }

    @ViewBuilder private var overlay: some View {
        if let sel = model.selectedID {
            if (model.panes[sel] ?? []).isEmpty, let w = model.byID[sel], w.state != "Running" {
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
