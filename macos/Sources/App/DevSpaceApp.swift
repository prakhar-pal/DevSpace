import SwiftUI
import DevSpaceCore

@main
struct DevSpaceApp: App {
    init() {
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
