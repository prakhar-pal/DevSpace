import SwiftUI

/// Stack 4: a temporary two-pane layout — debug workspace list (left) driven by
/// the poll loop, terminal spike (right). Stack 5 replaces the left pane with
/// the real Sidebar.
struct ContentView: View {
    @StateObject private var store = WorkspaceStore()

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceDebugList(workspaces: store.workspaces)
                .frame(width: 240)
            Divider()
            TerminalHostView()
        }
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear { store.start() }
    }
}

#Preview {
    ContentView()
}
