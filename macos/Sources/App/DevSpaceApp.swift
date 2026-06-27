import SwiftUI
import DevSpaceCore

@main
struct DevSpaceApp: App {
    init() {
        // Repair PATH first (before any subprocess/thread), so devpod resolves
        // when launched via Finder/LaunchServices. No-op if devpod is already
        // on PATH (e.g. launched from a terminal).
        PathEnv.repair()
        Log.write("DevSpace launched (logging enabled: \(Log.isEnabled))")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}
