import Foundation

// Port of src-tauri/src/hooks.rs — idempotently inject the DevSpace Claude Code
// notification hooks into a pod's ~/.claude/settings.json (and write the
// ~/.devspace-notify helper) via `devpod ssh`. Pod id, event label, port, and
// token are baked into the curl command literally (no in-pod env reliance).
public enum Hooks {
    // (settings key, optional matcher, literal event label sent to the desktop)
    static let hookEvents: [(key: String, matcher: String?, label: String)] = [
        ("Notification", nil, "Notification"),
        ("Stop", nil, "Stop"),
        ("PreToolUse", "AskUserQuestion", "AskUserQuestion"),
    ]

    static func hookCommand(_ eventLabel: String, podID: String, token: String) -> String {
        let port = SSH.podForwardPort
        return "curl -s -m 2 -X POST "
            + "-d '{\"pod_id\":\"\(podID)\",\"event\":\"\(eventLabel)\",\"token\":\"\(token)\"}' "
            + "http://localhost:\(port)/notify >/dev/null 2>&1 || true"
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
            return c.contains("/notify") && c.contains("pod_id")
        }
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
            arr.removeAll { isDevspaceEntry($0) }
            arr.append(devspaceHookEntry(matcher: matcher, label: label, podID: podID, token: token))
            hooks[key] = arr
        }
        root["hooks"] = hooks
        return root
    }

    /// The manual-trigger helper written to ~/.devspace-notify in the pod.
    static func notifyHelperScript(podID: String, token: String) -> String {
        let port = SSH.podForwardPort
        return """
        #!/usr/bin/env bash
        # DevSpace manual notification trigger. Must run inside the DevSpace
        # terminal — it uses the reverse SSH tunnel this session set up.
        event="${1:-Stop}"
        curl -s -m 2 -X POST -d "{\\"pod_id\\":\\"\(podID)\\",\\"event\\":\\"$event\\",\\"token\\":\\"\(token)\\"}" http://localhost:\(port)/notify && echo "devspace-notify: sent event=$event" || echo "devspace-notify: failed (is this the DevSpace terminal?)"

        """
    }

    static func base64Encode(_ data: Data) -> String { data.base64EncodedString() }

    /// Read the pod's settings.json, merge the hooks, and write it back (plus the
    /// helper) via `devpod ssh --command`. Idempotent; best-effort.
    public static func inject(_ runner: CommandRunning, podID: String, token: String) throws {
        try Devpod.validateId(podID)
        let read = try runner.run([
            "ssh", "--command",
            "cat \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\" 2>/dev/null || echo '{}'",
            "--", podID,
        ])
        let existing = try? JSONSerialization.jsonObject(
            with: Data(read.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        )
        let merged = mergeSettings(existing, podID: podID, token: token)
        let serialized = try JSONSerialization.data(withJSONObject: merged)
        let settingsB64 = serialized.base64EncodedString()
        let helperB64 = base64Encode(Data(notifyHelperScript(podID: podID, token: token).utf8))
        let cmd = "CLAUDE_DIR=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\" "
            + "&& mkdir -p \"$CLAUDE_DIR\" "
            + "&& echo \(settingsB64) | base64 -d > \"$CLAUDE_DIR/settings.json\" "
            + "&& echo \(helperB64) | base64 -d > ~/.devspace-notify "
            + "&& chmod +x ~/.devspace-notify"
        _ = try runner.run(["ssh", "--command", cmd, "--", podID])
    }
}
