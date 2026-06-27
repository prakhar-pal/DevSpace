import SwiftUI
import DevSpaceCore

/// Port of src/components/ActionPanel.tsx — shown for a selected, non-running
/// workspace: metadata + a Start button.
struct ActionPanelView: View {
    let workspace: WorkspaceView
    let displayName: String
    let onStart: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(displayName)
                        .font(.system(size: 22, weight: .semibold))
                    Spacer()
                    stateBadge
                }
                .padding(.bottom, 20)

                field("Provider", workspace.provider)
                field("Source", workspace.source)
                field("Last used", workspace.lastUsed)

                if workspace.state != "Loading" {
                    Button { onStart(workspace.id) } label: {
                        Text("Start")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 18).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .padding(.top, 24)
                }
            }
            .padding(28)
            .frame(maxWidth: 540, alignment: .leading)
            .background(Color(red: 0.094, green: 0.094, blue: 0.094)) // #181818
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.16)))
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var stateBadge: some View {
        Text(workspace.state.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch workspace.state.lowercased() {
        case "running": .green
        case "busy": .orange
        case "stopped", "loading": .gray
        default: .red
        }
    }

    @ViewBuilder private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 14))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(Divider(), alignment: .bottom)
    }
}
