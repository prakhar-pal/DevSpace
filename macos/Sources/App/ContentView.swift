import SwiftUI

/// Stack 2: the whole window is the libghostty terminal surface (the spike).
/// Later stacks wrap this in the sidebar + action chrome.
struct ContentView: View {
    var body: some View {
        TerminalHostView()
            .frame(minWidth: 800, minHeight: 600)
            .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
