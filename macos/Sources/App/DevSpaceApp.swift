import SwiftUI
import DevSpaceCore

@main
struct DevSpaceApp: App {
    @StateObject private var model: AppModel

    init() {
        // Repair PATH first (before any subprocess/thread), so devpod resolves
        // when launched via Finder/LaunchServices. No-op if devpod is already
        // on PATH (e.g. launched from a terminal).
        PathEnv.repair()
        Log.write("DevSpace launched (logging enabled: \(Log.isEnabled))")
        // Construct the model eagerly (a `let`, not the deferred autoclosure
        // form) so AppModel.init — which starts the poll loop — runs at app
        // launch rather than waiting for the scene to install StateObject.
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}
