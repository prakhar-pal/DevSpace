import Foundation

// Port of src-tauri/src/hooks.rs — idempotently inject the DevSpace Claude Code
// notification hooks into a pod's ~/.claude/settings.json via `devpod ssh`.
// Dev builds may also write the ~/.devspace-notify helper. Pod id, event label,
// and token are baked into the curl command; its port is resolved from live
// tunnels at invocation time, preferring production before development.
public enum Hooks {
    // (settings key, optional matcher, literal event label sent to the desktop)
    static let hookEvents: [(key: String, matcher: String?, label: String)] = [
        ("Notification", nil, "Notification"),
        ("Stop", nil, "Stop"),
        ("PreToolUse", "AskUserQuestion", "AskUserQuestion"),
    ]

    static func hookCommand(_ eventLabel: String, podID: String, token: String) -> String {
        return PodPortRouting.resolverShell
            + "\n"
            + "port=\"$(__devspace_resolve_port)\" || exit 0; curl -s -m 2 -X POST "
            + "-d '{\"pod_id\":\"\(podID)\",\"event\":\"\(eventLabel)\",\"token\":\"\(token)\"}' "
            + "http://localhost:$port/notify >/dev/null 2>&1 || true"
    }

    /// True if a hook entry is one DevSpace injected (its command POSTs a pod_id
    /// to /notify) — so re-injecting replaces stale entries instead of stacking.
    static func isDevspaceEntry(_ entry: Any) -> Bool {
        guard
            let e = entry as? [String: Any],
            let hooks = e["hooks"] as? [Any]
        else { return false }
        return hooks.contains { h in
            guard let hd = h as? [String: Any], let c = hd["command"] as? String else { return false }
            return isDevspaceCommand(c)
        }
    }

    private static func isDevspaceCommand(_ command: String) -> Bool {
        // Recognize our resolver, including hooks installed before explicit
        // markers, without deleting another tool's /notify command.
        command.contains("__devspace_resolve_port") &&
            command.contains("http://localhost:$port/notify") && command.contains("pod_id")
    }

    private static func preservingUnmanagedCommands(_ entry: Any) -> Any? {
        guard isDevspaceEntry(entry), var object = entry as? [String: Any],
              let commands = object["hooks"] as? [Any] else { return entry }
        let unrelated = commands.filter { command in
            guard let value = command as? [String: Any], let text = value["command"] as? String else { return true }
            return !isDevspaceCommand(text)
        }
        guard !unrelated.isEmpty else { return nil }
        object["hooks"] = unrelated
        return object
    }

    static func devspaceHookEntry(matcher: String?, label: String, podID: String, token: String) -> [String: Any] {
        var entry: [String: Any] = [
            "hooks": [["type": "command", "command": hookCommand(label, podID: podID, token: token)]],
        ]
        if let matcher { entry["matcher"] = matcher }
        return entry
    }

    /// Merge the DevSpace hooks into an existing settings document (or empty),
    /// idempotently. Preserves unrelated hooks; tolerates malformed values.
    public static func mergeSettings(_ existing: Any?, podID: String, token: String) -> [String: Any] {
        var root = (existing as? [String: Any]) ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:] // wrong-typed -> treat as missing
        for (key, matcher, label) in hookEvents {
            var arr = (hooks[key] as? [Any]) ?? [] // wrong-typed -> treat as missing
            arr = arr.compactMap(preservingUnmanagedCommands)
            arr.append(devspaceHookEntry(matcher: matcher, label: label, podID: podID, token: token))
            hooks[key] = arr
        }
        root["hooks"] = hooks
        return root
    }

    /// Remove only entries previously injected by DevSpace. Returns nil when
    /// there is nothing to remove so disconnecting never creates settings.json.
    static func removingSettings(_ existing: [String: Any]) -> [String: Any]? {
        guard var hooks = existing["hooks"] as? [String: Any] else { return nil }
        var removed = false
        for (event, value) in Array(hooks) {
            guard let entries = value as? [Any] else { continue }
            guard entries.contains(where: isDevspaceEntry) else { continue }
            removed = true
            let remaining = entries.compactMap(preservingUnmanagedCommands)
            hooks[event] = remaining.isEmpty ? nil : remaining
        }
        guard removed else { return nil }
        var root = existing
        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = hooks }
        return root
    }

    /// Remove DevSpace's Claude hooks from a pod without disturbing other
    /// tools' hooks or settings. Used when the app disconnects from a pod.
    public static func remove(_ runner: CommandRunning, podID: String, preservingTunnelOnPort: UInt16? = nil) throws {
        try Devpod.validateId(podID)
        let probe = preservingTunnelOnPort.map {
            "curl --noproxy '*' -fsS --max-time 1 -o /dev/null http://127.0.0.1:\($0)/ 2>/dev/null"
        }
        let settingsRead = "if [ -e \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\" ]; then cat \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\"; else printf '{}'; fi"
        let readCommand = probe.map {
            "if \($0); then printf '__DEVSPACE_OTHER_TUNNEL_ACTIVE__'; else \(settingsRead); fi"
        } ?? settingsRead
        let read = try runner.run([
            "ssh", "--command",
            readCommand,
            "--start-services=false",
            "--", podID,
        ])
        if read == "__DEVSPACE_OTHER_TUNNEL_ACTIVE__" { return }
        guard let existing = try JSONSerialization.jsonObject(
            with: Data(read.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        ) as? [String: Any] else {
            throw DevpodError("Claude settings must be a JSON object; existing settings left untouched")
        }
        guard let cleaned = removingSettings(existing) else { return }
        let originalB64 = Data(read.utf8).base64EncodedString()
        let serialized = try JSONSerialization.data(withJSONObject: cleaned)
        let settingsB64 = serialized.base64EncodedString()
        let cmd = "umask 077; CLAUDE_DIR=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\" "
            + "&& mkdir -p \"$CLAUDE_DIR\" "
            + "&& lock_dir=\"$CLAUDE_DIR/.devspace-settings.lock\" && mkdir \"$lock_dir\" "
            + "&& trap 'rmdir -- \"$lock_dir\"' EXIT && trap 'exit 1' HUP INT TERM "
            + (probe.map { "&& if \($0); then exit 0; fi " } ?? "")
            + "&& settings_tmp=$(mktemp \"$CLAUDE_DIR/.devspace-settings-XXXXXX\") "
            + "&& trap 'rm -f -- \"$settings_tmp\"; rmdir -- \"$lock_dir\"' EXIT "
            + "&& echo \(settingsB64) | base64 -d > \"$settings_tmp\" "
            + "&& chmod 600 \"$settings_tmp\" "
            + "&& current_b64=$(if [ -e \"$CLAUDE_DIR/settings.json\" ]; then base64 < \"$CLAUDE_DIR/settings.json\"; else printf e30=; fi) "
            + "&& current_b64=$(printf '%s' \"$current_b64\" | tr -d '\\n') "
            + "&& [ \"$current_b64\" = '\(originalB64)' ] "
            + "&& mv -f -- \"$settings_tmp\" \"$CLAUDE_DIR/settings.json\""
        _ = try runner.run(["ssh", "--command", cmd, "--start-services=false", "--", podID])
    }

    /// The manual-trigger helper written to ~/.devspace-notify in the pod.
    static func notifyHelperScript(podID: String, token: String) -> String {
        return """
        #!/usr/bin/env bash
        # DevSpace manual notification trigger. Run inside a DevSpace-connected
        # pod; it selects an available reverse SSH tunnel when invoked.
        \(PodPortRouting.resolverShell)
        event="${1:-Stop}"
        port="$(__devspace_resolve_port)" || {
          echo "devspace-notify: failed (is this the DevSpace terminal?)"
          exit 0
        }
        curl -s -m 2 -X POST -d "{\\"pod_id\\":\\"\(podID)\\",\\"event\\":\\"$event\\",\\"token\\":\\"\(token)\\"}" http://localhost:$port/notify && echo "devspace-notify: sent event=$event" || echo "devspace-notify: failed (is this the DevSpace terminal?)"

        """
    }

    static func base64Encode(_ data: Data) -> String { data.base64EncodedString() }

    /// Read the pod's settings.json, merge the hooks, and write it back via
    /// `devpod ssh --command`. Optionally install the manual helper.
    /// Idempotent; best-effort.
    public static func inject(
        _ runner: CommandRunning,
        podID: String,
        token: String,
        installManualHelper: Bool
    ) throws {
        try Devpod.validateId(podID)
        let read = try runner.run([
            "ssh", "--command",
            "if [ -e \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\" ]; then cat \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\"; else printf '{}'; fi",
            "--start-services=false",
            "--", podID,
        ])
        guard let existing = try JSONSerialization.jsonObject(
            with: Data(read.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        ) as? [String: Any] else {
            throw DevpodError("Claude settings must be a JSON object; existing settings left untouched")
        }
        let merged = mergeSettings(existing, podID: podID, token: token)
        let serialized = try JSONSerialization.data(withJSONObject: merged)
        let settingsB64 = serialized.base64EncodedString()
        let originalB64 = Data(read.utf8).base64EncodedString()
        var cmd = "umask 077; CLAUDE_DIR=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\" "
            + "&& mkdir -p \"$CLAUDE_DIR\" "
            + "&& lock_dir=\"$CLAUDE_DIR/.devspace-settings.lock\" && mkdir \"$lock_dir\" "
            + "&& trap 'rmdir -- \"$lock_dir\"' EXIT && trap 'exit 1' HUP INT TERM "
            + "&& settings_tmp=$(mktemp \"$CLAUDE_DIR/.devspace-settings-XXXXXX\") "
            + "&& trap 'rm -f -- \"$settings_tmp\"; rmdir -- \"$lock_dir\"' EXIT "
            + "&& echo \(settingsB64) | base64 -d > \"$settings_tmp\" "
            + "&& chmod 600 \"$settings_tmp\" "
            + "&& current_b64=$(if [ -e \"$CLAUDE_DIR/settings.json\" ]; then base64 < \"$CLAUDE_DIR/settings.json\"; else printf e30=; fi) "
            + "&& current_b64=$(printf '%s' \"$current_b64\" | tr -d '\\n') "
            + "&& [ \"$current_b64\" = '\(originalB64)' ] "
            + "&& mv -f -- \"$settings_tmp\" \"$CLAUDE_DIR/settings.json\""
        if installManualHelper {
            let helperB64 = base64Encode(Data(notifyHelperScript(podID: podID, token: token).utf8))
            cmd += " && helper_tmp=$(mktemp \"$HOME/.devspace-notify-XXXXXX\")"
            cmd += " && trap 'rm -f -- \"$settings_tmp\" \"$helper_tmp\"; rmdir -- \"$lock_dir\"' EXIT"
            cmd += " && echo \(helperB64) | base64 -d > \"$helper_tmp\""
            cmd += " && chmod 700 \"$helper_tmp\" && mv -f -- \"$helper_tmp\" ~/.devspace-notify"
        }
        _ = try runner.run(["ssh", "--command", cmd, "--start-services=false", "--", podID])
    }
}
