import Foundation

// Port of src-tauri/src/poller.rs — merge the workspace list with per-workspace
// status (fetched concurrently), and a background loop that emits twice per
// cycle (names first, then resolved statuses) carrying a status cache across
// cycles to avoid flicker.

public struct WorkspaceView: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let provider: String
    public let source: String
    public let lastUsed: String
    public let state: String
    public let error: String?

    public init(
        id: String,
        provider: String,
        source: String,
        lastUsed: String,
        state: String,
        error: String?
    ) {
        self.id = id
        self.provider = provider
        self.source = source
        self.lastUsed = lastUsed
        self.state = state
        self.error = error
    }
}

/// A poll cycle's result, tagged when the cycle starts so consumers can reject
/// an older result that arrives after a lifecycle command has completed.
public struct PollUpdate: Equatable, Sendable {
    public let revision: UInt64
    public let views: [WorkspaceView]
    public let hasFreshStatuses: Bool

    public init(
        revision: UInt64,
        views: [WorkspaceView],
        hasFreshStatuses: Bool = true
    ) {
        self.revision = revision
        self.views = views
        self.hasFreshStatuses = hasFreshStatuses
    }
}

/// Shared monotonic sequence for background polls and lifecycle refreshes.
public final class PollRevisionSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    public init() {}

    public func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

/// How many `devpod status` calls run concurrently per poll cycle.
let maxConcurrentStatus = 4

private final class StatusResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Result<WorkspaceStatus, DevpodError>] = [:]

    func set(_ value: Result<WorkspaceStatus, DevpodError>, for id: String) {
        lock.lock()
        values[id] = value
        lock.unlock()
    }

    var snapshot: [String: Result<WorkspaceStatus, DevpodError>] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

public enum Poller {
    /// Merge the workspace list with a map of id -> status (or error).
    public static func merge(
        _ workspaces: [Workspace],
        _ statuses: [String: Result<WorkspaceStatus, DevpodError>]
    ) -> [WorkspaceView] {
        workspaces.map { w in
            let source = w.source.gitRepository ?? w.source.localFolder ?? ""
            let state: String
            let error: String?
            switch statuses[w.id] {
            case let .success(s):
                state = s.state
                error = nil
            case let .failure(e):
                // A genuine status error surfaces as Unknown (+ tooltip).
                state = "Unknown"
                error = e.message
            case .none:
                // Status not fetched yet this cycle: Loading, not an error.
                state = "Loading"
                error = nil
            }
            return WorkspaceView(
                id: w.id,
                provider: w.provider.name,
                source: source,
                lastUsed: w.lastUsed,
                state: state,
                error: error
            )
        }
    }

    /// Fetch each workspace's status, up to `maxConcurrentStatus` in flight.
    public static func fetchStatuses(
        _ runner: CommandRunning,
        _ workspaces: [Workspace]
    ) -> [String: Result<WorkspaceStatus, DevpodError>] {
        let result = StatusResults()
        let sem = DispatchSemaphore(value: maxConcurrentStatus)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        for w in workspaces {
            sem.wait()
            group.enter()
            queue.async {
                let r: Result<WorkspaceStatus, DevpodError>
                do {
                    r = .success(try Devpod.status(runner, id: w.id))
                } catch let e as DevpodError {
                    r = .failure(e)
                } catch {
                    r = .failure(DevpodError("\(error)"))
                }
                result.set(r, for: w.id)
                sem.signal()
                group.leave()
            }
        }
        group.wait()
        return result.snapshot
    }

    /// One full poll cycle: list, fetch all statuses, merge.
    public static func pollOnce(_ runner: CommandRunning) throws -> [WorkspaceView] {
        let workspaces = try Devpod.list(runner)
        let statuses = fetchStatuses(runner, workspaces)
        return merge(workspaces, statuses)
    }
}

/// Background poll loop. Each cycle emits twice: the workspace names immediately
/// after the fast `devpod list` (unknown statuses shown as Loading), then again
/// once the per-workspace status sweep resolves. A status cache carried across
/// cycles keeps last-known states instead of flickering to Loading.
/// Thread-safe set of workspace ids to skip during status polling (hidden
/// workspaces). Updated from the main actor, read from the poll thread.
public final class ExcludedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    public init() {}
    public func set(_ next: Set<String>) { lock.lock(); ids = next; lock.unlock() }
    public func snapshot() -> Set<String> { lock.lock(); defer { lock.unlock() }; return ids }
}

public final class PollLoop: @unchecked Sendable {
    private let runner: CommandRunning
    private let interval: TimeInterval
    private let excluded: ExcludedIDs
    private let revisions: PollRevisionSource
    private let stop = StopFlag()

    public init(
        runner: CommandRunning,
        interval: TimeInterval = 5,
        excluded: ExcludedIDs = ExcludedIDs(),
        revisions: PollRevisionSource = PollRevisionSource()
    ) {
        self.runner = runner
        self.interval = interval
        self.excluded = excluded
        self.revisions = revisions
    }

    public func start(emit: @escaping @Sendable (PollUpdate) -> Void) {
        guard !stop.isSet else { return }
        let runner = self.runner
        let interval = self.interval
        let excluded = self.excluded
        let revisions = self.revisions
        let stop = self.stop
        Thread.detachNewThread {
            var cache: [String: Result<WorkspaceStatus, DevpodError>] = [:]
            // Applied per FRESH fetch (not per emit — each fetch is emitted
            // twice) to suppress k8s' transient Running-after-stop reports.
            var debouncer = RunningDebouncer()
            while !stop.isSet {
                let revision = revisions.next()
                if let workspaces = try? Devpod.list(runner) {
                    emit(PollUpdate(
                        revision: revision,
                        views: Poller.merge(workspaces, cache),
                        hasFreshStatuses: false
                    ))
                    // Skip `devpod status` for excluded (hidden) workspaces.
                    let skip = excluded.snapshot()
                    let toFetch = workspaces.filter { !skip.contains($0.id) }
                    cache = debouncer.filter(Poller.fetchStatuses(runner, toFetch))
                    emit(PollUpdate(
                        revision: revision,
                        views: Poller.merge(workspaces, cache),
                        hasFreshStatuses: true
                    ))
                }
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }

    public func stop_() { stop.set() }
    deinit { stop.set() }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
