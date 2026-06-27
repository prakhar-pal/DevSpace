import SwiftUI
import DevSpaceCore

/// Observable wrapper around the background poll loop — the SwiftUI analog of
/// the Rust `workspaces-updated` event stream.
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspaces: [WorkspaceView] = []
    private let loop: PollLoop

    init(runner: CommandRunning = DevpodCLI(), interval: TimeInterval = 5) {
        loop = PollLoop(runner: runner, interval: interval)
    }

    func start() {
        loop.start { [weak self] views in
            DispatchQueue.main.async { self?.workspaces = views }
        }
    }
}

/// Temporary debug list (Stack 4). Replaced by the real Sidebar in Stack 5.
struct WorkspaceDebugList: View {
    let workspaces: [WorkspaceView]

    var body: some View {
        List(workspaces) { w in
            HStack(spacing: 8) {
                Circle().fill(color(for: w.state)).frame(width: 8, height: 8)
                Text(w.id).font(.system(size: 12)).lineLimit(1)
                Spacer()
                Text(w.state).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    private func color(for state: String) -> Color {
        switch state {
        case "Running": .green
        case "Busy": .orange
        case "Unknown": .red
        default: .gray
        }
    }
}
