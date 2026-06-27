import SwiftUI
import DevSpaceCore

/// The workspace sidebar — port of src/components/Sidebar.tsx.
struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let parts = model.split
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(parts.visible) { w in
                        WorkspaceRow(model: model, workspace: w, isHidden: false)
                    }
                    .onMove { from, to in
                        var ids = parts.visible.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        model.applyVisibleOrder(ids)
                    }
                }

                if !parts.hidden.isEmpty {
                    Section {
                        ForEach(
                            SidebarLayout.hiddenRows(
                                parts.hidden,
                                collapsed: model.hiddenCollapsed,
                                selectedID: model.selectedID
                            )
                        ) { w in
                            WorkspaceRow(model: model, workspace: w, isHidden: true)
                        }
                    } header: {
                        Button(action: model.toggleHiddenCollapsed) {
                            HStack(spacing: 6) {
                                Image(systemName: model.hiddenCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Hidden (\(parts.hidden.count))")
                                    .font(.system(size: 11, weight: .semibold))
                                    .textCase(.uppercase)
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button { model.guideOpen = true } label: {
                Label("Guide", systemImage: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 240)
        .background(Color(red: 0.094, green: 0.094, blue: 0.106)) // #18181b
    }
}

private struct WorkspaceRow: View {
    @ObservedObject var model: AppModel
    let workspace: WorkspaceView
    let isHidden: Bool
    @State private var hovering = false

    private var isSelected: Bool { model.selectedID == workspace.id }
    private var name: String { model.aliases[workspace.id] ?? workspace.id }

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if model.badges.contains(workspace.id) {
                Circle().fill(.blue).frame(width: 6, height: 6)
            }
            if !isHidden, workspace.state != "Stopped", hovering || isSelected {
                Button { model.stop(workspace.id) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop devpod")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color(white: 0.27) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(workspace.id) }
        .help(workspace.error ?? workspace.source)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            Button("Set friendly name…") { model.beginRename(workspace.id) }
            if model.opened.contains(workspace.id) {
                Button("Reload SSH Session") { model.reload(workspace.id) }
            }
            Divider()
            Button("Open in Zed") { model.openInZed(workspace.id) }
            Divider()
            if isHidden {
                Button("Show") { model.unhide(workspace.id) }
            } else {
                Button("Hide") { model.hide(workspace.id) }
            }
        }
    }

    @ViewBuilder private var statusDot: some View {
        if model.starting.contains(workspace.id) || workspace.state == "Loading" {
            ProgressView().controlSize(.small).frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(color(for: SidebarLayout.statusColorName(workspace.state)))
                .frame(width: 9, height: 9)
        }
    }

    private func color(for name: String) -> Color {
        switch name {
        case "green": .green
        case "amber": .orange
        case "red": .red
        default: .gray
        }
    }
}
