import SwiftUI

/// Port of src/components/RenameModal.tsx.
struct RenameSheet: View {
    let workspaceID: String
    @State var name: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set friendly name").font(.headline)
            Text("Workspace \(workspaceID)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Friendly name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(name) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Set friendly name") { onSubmit(name) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Port of src/components/GuideModal.tsx.
struct GuideSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Using DevSpace").font(.headline)
                    Text("Manage your DevPod workspaces from one window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Keyboard shortcuts") {
                        row("⌘1…⌘9", "Jump to the Nth visible workspace.")
                        row("⌘B", "Toggle the sidebar to give the terminal more room.")
                        row("⌘R", "Reload the selected workspace's SSH session.")
                        row("⌘O", "Open the selected workspace's folder in Zed.")
                        row("⌘T", "Open another terminal tab for the selected workspace.")
                        row("⌘V", "Paste a screenshot/image directly into the terminal — DevSpace copies it to the pod and inserts its path so Claude Code can read it.")
                        row("⌘⇧T", "Switch to the next terminal tab.")
                        row("⌘⌥↑ / ⌘⌥↓", "Move the selected workspace up / down in the sidebar.")
                        row("Esc", "Close this guide.")
                    }
                    section("Workspaces") {
                        row("Sidebar list", "Every DevPod workspace is listed. The colored dot is its status — green running, grey stopped, amber busy. Status refreshes every few seconds.")
                        row("Select", "Click a workspace to open it. Stopped pods show a details panel; running pods drop you into a terminal.")
                        row("Blue dot", "Claude Code in that pod posted a notification. Selecting the workspace clears it.")
                    }
                    section("Start & stop") {
                        row("Start", "Select a stopped workspace and press Start. The live devpod up log streams until it's ready, then the terminal opens.")
                        row("Stop", "Hover a running workspace and click the ⬛ stop button, or use Stop on its status card. Exiting a shell only disconnects — the workspace keeps running.")
                    }
                    section("The terminal") {
                        row("Auto-connect", "Workspaces that are running when DevSpace launches (or that you start) SSH in automatically. After you disconnect, the status card's Connect reopens the session — DevSpace never wakes a stopped workspace on its own.")
                        row("Copy / paste", "⌘C copies the selection, ⌘V pastes text as usual. An image on the clipboard (e.g. a screenshot) is copied to the pod instead, with its path inserted for Claude Code to read. URLs are ⌘-clickable.")
                        row("Newline", "⇧Enter inserts a newline without sending.")
                        row("Reload session", "⌘R, or right-click a running workspace → Reload SSH Session.")
                        row("Multiple terminals", "⌘T (or right-click → New Terminal) opens another shell to the same pod; the tab strip appears once a second terminal is open. Tabs are titled by the shell's current folder. Closing the last one disconnects (the status card offers Connect); extra tabs just close.")
                    }
                    section("Organize the sidebar") {
                        row("Reorder", "Right-click → Move Up / Move Down (or ⌘⌥↑ / ⌘⌥↓) — the order is saved.")
                        row("Rename", "Right-click → Set friendly name… The real ID is untouched.")
                        row("Hide / show", "Right-click → Hide tucks a workspace into the Hidden section; Show brings it back.")
                        row("Open in Zed", "Right-click → Open in Zed launches the Zed editor in the workspace.")
                    }
                    section("Claude Code notifications") {
                        row("Automatic", "Opening a workspace wires up Claude Code hooks over a reverse SSH tunnel; you get a notification (or dock bounce + blue dot) when Claude finishes or needs input.")
#if DEBUG
                        row("Manual test", "Run ~/.devspace-notify inside a pod's terminal to fire a test notification.")
#endif
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 560, height: 560)
    }

    @ViewBuilder private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder private func row(_ how: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(how)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(text).font(.system(size: 13))
            Spacer(minLength: 0)
        }
    }
}
