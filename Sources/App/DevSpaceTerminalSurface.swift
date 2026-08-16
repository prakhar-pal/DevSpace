import AppKit
import GhosttyTerminal
import SwiftUI

@MainActor
final class DevSpaceTerminalView: AppTerminalView {
    var handleKeyEquivalent: (NSEvent) -> Bool = { _ in false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct DevSpaceTerminalSurfaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var state: TerminalViewState
    let handleKeyEquivalent: (NSEvent) -> Bool

    var body: some View {
        DevSpaceTerminalViewRepresentable(
            state: state,
            handleKeyEquivalent: handleKeyEquivalent
        )
        .background(.clear)
        .onChange(of: colorScheme) { _, newScheme in
            state.adopt(colorScheme: newScheme)
        }
        .onAppear {
            state.adopt(colorScheme: colorScheme)
        }
    }
}

private struct DevSpaceTerminalViewRepresentable: NSViewRepresentable {
    let state: TerminalViewState
    let handleKeyEquivalent: (NSEvent) -> Bool

    func makeNSView(context _: Context) -> DevSpaceTerminalView {
        let view = DevSpaceTerminalView(frame: .zero)
        view.delegate = state
        configure(view)
        return view
    }

    func updateNSView(_ view: DevSpaceTerminalView, context _: Context) {
        configure(view)
    }

    static func dismantleNSView(
        _ view: DevSpaceTerminalView,
        coordinator _: ()
    ) {
        view.handleKeyEquivalent = { _ in false }
    }

    private func configure(_ view: DevSpaceTerminalView) {
        view.handleKeyEquivalent = handleKeyEquivalent
        if let currentController = view.controller,
           currentController === state.controller {
            // Preserve the current surface and its scrollback.
        } else {
            view.controller = state.controller
        }
        // TerminalSurfaceCoordinator ignores equivalent assignments.
        view.configuration = state.configuration
    }
}
