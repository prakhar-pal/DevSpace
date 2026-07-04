import DevSpaceCore
import SwiftUI

/// The workspace sidebar — port of src/components/Sidebar.tsx.
struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let parts = model.split
        VStack(spacing: 0) {
            // Visible workspaces — greedy List (fills space) with drag-reorder.
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
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 26)

            // Hidden section — pinned to the bottom (above Guide).
            if !parts.hidden.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    Button(action: model.toggleHiddenCollapsed) {
                        HStack(spacing: 6) {
                            Image(
                                systemName: model.hiddenCollapsed ? "chevron.right" : "chevron.down"
                            )
                            .font(.system(size: 9, weight: .bold))
                            Text("Hidden (\(parts.hidden.count))")
                                .font(.system(size: 11, weight: .semibold))
                                .textCase(.uppercase)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverTintFill(idle: .secondary, hover: .primary, fill: .white.opacity(0.08))
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                    ForEach(
                        SidebarLayout.hiddenRows(
                            parts.hidden,
                            collapsed: model.hiddenCollapsed,
                            selectedID: model.selectedID
                        )
                    ) { w in
                        WorkspaceRow(model: model, workspace: w, isHidden: true)
                    }
                    .padding(.horizontal, 1)
                }
                .padding(.bottom, 4)
            }

            Divider()
            Button {
                model.guideOpen = true
            } label: {
                Label("Guide", systemImage: "questionmark.circle")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTintFill(idle: .secondary, hover: .primary, fill: .white.opacity(0.08))
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(width: 240)
        .background(Color(red: 0.094, green: 0.094, blue: 0.106))  // #18181b
    }
}

private struct WorkspaceRow: View {
    @ObservedObject var model: AppModel
    let workspace: WorkspaceView
    let isHidden: Bool
    @State private var hovering = false

    private var isSelected: Bool { model.selectedID == workspace.id }
    private var name: String { model.aliases[workspace.id] ?? workspace.id }
    private var showControls: Bool { hovering || isSelected }

    var body: some View {
        HStack(spacing: nil) {
            statusDot
            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if model.badges.contains(workspace.id) {
                Circle().fill(.blue).frame(width: 6, height: 6)
            }
            // Stop (running only) + the ⋯ menu. Kept in the layout and faded so
            // the row width is stable and the menu doesn't close on hover loss.
            if !isHidden, workspace.state != "Stopped" {
                Button {
                    model.stop(workspace.id)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTintFill(idle: .secondary, hover: .red, fill: .red.opacity(0.18))
                .opacity(showControls ? 1 : 0)
                .help("Stop devpod")
            }
            Menu {
                menuItems
            } label: {
                // Drawn vertical dots. Uses .menuStyle(.button)+.buttonStyle(.plain)
                // so the Menu renders the label as a real view (custom shapes
                // survive) — .borderlessButton would rasterize it to a template
                // and drop the shapes.
                VStack(spacing: 2) {
                    Circle().frame(width: 2, height: 2)
                    Circle().frame(width: 2, height: 2)
                    Circle().frame(width: 2, height: 2)
                }
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(.white)
            .hoverFill()
            .opacity(showControls ? 1 : 0)
            .help("More options")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color(white: 0.27) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(workspace.id) }
        .help(workspace.error ?? workspace.source)
        .listRowInsets(EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Set friendly name…") { model.beginRename(workspace.id) }
        if model.opened.contains(workspace.id) {
            Button("Reload SSH Session") { model.reload(workspace.id) }
        }
        // Only for running pods: the remote open rides the live SSH alias, and
        // opening a stopped pod's folder isn't possible without starting it.
        if workspace.state == "Running" {
            Divider()
            Button("Open in Zed") { model.openInZed(workspace.id) }
        }
        Divider()
        if isHidden {
            Button("Show") { model.unhide(workspace.id) }
        } else {
            Button("Hide") { model.hide(workspace.id) }
        }
    }

    @ViewBuilder private var statusDot: some View {
        // Hidden workspaces aren't status-polled (except when selected), so show
        // a solid dot rather than a perpetual spinner.
        if !isHidden, model.starting.contains(workspace.id) || workspace.state == "Loading" {
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

// MARK: - Hover styles

/// Background fill that appears on hover (foreground left untouched). Used by the
/// ⋯ menu, which manages its own white tint.
private struct HoverFill: ViewModifier {
    var color: Color = .white.opacity(0.12)
    var radius: CGFloat = 5
    @State private var over = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(over ? color : .clear))
            .onHover { over = $0 }
    }
}

/// Tint + background that change on hover. Used by the stop button (red), the
/// Hidden header, and the Guide button.
private struct HoverTintFill: ViewModifier {
    let idle: Color
    let hover: Color
    let fill: Color
    var radius: CGFloat = 5
    @State private var over = false
    func body(content: Content) -> some View {
        content
            .foregroundStyle(over ? hover : idle)
            .background(RoundedRectangle(cornerRadius: radius).fill(over ? fill : .clear))
            .onHover { over = $0 }
    }
}

extension View {
    fileprivate func hoverFill(_ color: Color = .white.opacity(0.12), radius: CGFloat = 5)
        -> some View
    {
        modifier(HoverFill(color: color, radius: radius))
    }

    fileprivate func hoverTintFill(idle: Color, hover: Color, fill: Color, radius: CGFloat = 5)
        -> some View
    {
        modifier(HoverTintFill(idle: idle, hover: hover, fill: fill, radius: radius))
    }
}
