import Foundation

/// Decides when devpod start/stop notifications fire, from the states the
/// poller observes.
///
/// Only definitive states (Running/Stopped) are tracked, so transient
/// Busy/Loading/Unknown blips can't fire or swallow a transition. The first
/// sighting of a pod (app launch, or first seen mid-session) baselines
/// silently.
///
/// "stopped" fires on the observed Running→Stopped transition. "started"
/// additionally waits until the app has actually SSH'd into the workspace
/// (``confirmSSH(_:)``) — a pod that devpod reports Running but that we never
/// reached never announces itself, and the notification means "ready to use",
/// not "provisioning". The confirm and the poll observation can arrive in
/// either order (`devpod up` opens SSH optimistically before the next poll).
public struct StateNotifyGate {
    /// Last definitive (Running/Stopped) state per pod.
    private var last: [String: String] = [:]
    private var baselined = false
    /// Pods whose Stopped→Running was observed but not yet SSH-confirmed.
    private var pendingStarted: Set<String> = []
    /// Pods SSH'd into since their last observed stop.
    private var confirmed: Set<String> = []

    public init() {}

    /// Feed one poll cycle's views; returns the events to notify now.
    public mutating func observe(_ views: [WorkspaceView]) -> [(id: String, event: String)] {
        defer { baselined = true }
        var events: [(id: String, event: String)] = []
        for w in views where w.state == "Running" || w.state == "Stopped" {
            let old = last.updateValue(w.state, forKey: w.id)
            guard baselined, let old, old != w.state else { continue }
            if w.state == "Stopped" {
                pendingStarted.remove(w.id)
                confirmed.remove(w.id)
                events.append((w.id, "stopped"))
            } else if confirmed.contains(w.id) {
                events.append((w.id, "started"))
            } else {
                pendingStarted.insert(w.id)
            }
        }
        return events
    }

    /// An SSH round-trip into the pod's workspace succeeded. Returns true when
    /// a deferred "started" notification should fire now.
    public mutating func confirmSSH(_ id: String) -> Bool {
        confirmed.insert(id)
        return pendingStarted.remove(id) != nil
    }

    /// Fire the pending "started" events for pods the app has chosen NOT to
    /// connect to (externally started workspaces under the no-auto-wake
    /// policy) — with no session there will never be an SSH confirm, so the
    /// (already debounced) poll observation is the only confirmation
    /// available. Pods in `connected` (open or opening sessions) stay pending
    /// for ``confirmSSH(_:)``. Returns the pod ids to notify, sorted.
    public mutating func releasePending(notIn connected: Set<String>) -> [String] {
        let released = pendingStarted.subtracting(connected)
        pendingStarted.subtract(released)
        return released.sorted()
    }

    /// Forget a pod's observed state so its next sighting baselines silently
    /// (a hidden pod resumes polling with a stale cache). Any live SSH confirm
    /// is kept — its session survives hiding.
    public mutating func reset(_ id: String) {
        last[id] = nil
        pendingStarted.remove(id)
    }
}
