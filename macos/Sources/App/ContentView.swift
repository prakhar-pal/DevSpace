import SwiftUI
import DevSpaceCore
// Imported in Stack 1 only to prove the libghostty-spm package links.
// The actual terminal surface is built in Stack 2.
import GhosttyKit
import GhosttyTerminal

struct ContentView: View {
    private var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "DevSpace"
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(displayName)
                .font(.system(size: 28, weight: .bold))
            Text("v\(DevSpaceCore.version)")
                .foregroundStyle(.secondary)
            Text("Native rewrite — scaffold (Stack 1)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.067, green: 0.067, blue: 0.067)) // #111
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
