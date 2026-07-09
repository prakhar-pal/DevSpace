import Foundation

/// Debounces false `Stopped→Running` flips in `devpod status` results.
///
/// On kubernetes, `devpod status` can report a pod Running for one fetch
/// shortly after `devpod stop` completes (teardown lag). Acting on that blip
/// is destructive: the app auto-reconnects, and `devpod ssh` *wakes the
/// stopped workspace back up* — resurrecting the pod and firing a spurious
/// started notification right after the stopped one.
///
/// A pod whose last accepted definitive state is Stopped must therefore
/// report Running on two consecutive status fetches before Running is passed
/// through; the first report is DROPPED, which merges as the non-definitive
/// "Loading". Holding it as "Stopped" instead would be wrong the other way:
/// a self-initiated `devpod up` opens the terminal optimistically before the
/// poller confirms, and a fabricated Stopped would make the lifecycle close
/// that fresh terminal one poll later. Loading is neutral — neither auto-open
/// nor pane-close acts on it. Everything else is immediate: first sightings
/// (app launch), Running→Stopped (panes must close promptly), non-definitive
/// states, and errors. Feed this FRESH fetch results only — the poll loop's
/// per-cycle double emit reuses one fetch, and counting emissions would
/// double-count it.
public struct RunningDebouncer {
    /// Last accepted definitive (Running/Stopped) state per pod.
    private var accepted: [String: String] = [:]
    /// Pods with exactly one not-yet-accepted Running report after a Stopped.
    private var pendingRunning: Set<String> = []

    public init() {}

    /// Filter one fresh status fetch, holding back unconfirmed revivals.
    public mutating func filter(
        _ statuses: [String: Result<WorkspaceStatus, DevpodError>]
    ) -> [String: Result<WorkspaceStatus, DevpodError>] {
        var out = statuses
        for (id, result) in statuses {
            guard case let .success(status) = result else { continue }
            switch status.state {
            case "Running":
                guard accepted[id] == "Stopped" else {
                    accepted[id] = "Running"
                    pendingRunning.remove(id)
                    continue
                }
                if pendingRunning.remove(id) != nil {
                    accepted[id] = "Running" // second consecutive Running: real
                } else {
                    pendingRunning.insert(id) // first Running after a stop: hold
                    out.removeValue(forKey: id) // absent merges as "Loading"
                }
            case "Stopped":
                accepted[id] = "Stopped"
                pendingRunning.remove(id)
            default:
                pendingRunning.remove(id) // Busy/Loading/… breaks the streak
            }
        }
        return out
    }
}
