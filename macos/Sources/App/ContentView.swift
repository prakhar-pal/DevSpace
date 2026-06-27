import SwiftUI
import DevSpaceCore

/// Stack 5: real sidebar + a placeholder main pane. Stack 6 fills the main pane
/// with the ActionPanel / StartLog / terminal lifecycle.
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
            if let id = model.selectedID, let w = model.byID[id] {
                VStack(spacing: 8) {
                    Text(model.aliases[id] ?? id).font(.title2.bold())
                    Text(w.state).foregroundStyle(.secondary)
                    if !w.source.isEmpty {
                        Text(w.source).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Actions + terminal arrive in Stack 6")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.top, 6)
                }
            } else {
                Text("Select a workspace").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView(model: AppModel())
}
