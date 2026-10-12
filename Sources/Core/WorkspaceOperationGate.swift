import Foundation

/// Serializes controller operations and invalidates results from work that was
/// superseded by shutdown/reload. It intentionally does not pretend to kill a
/// subprocess: command cancellation remains the responsibility of the process
/// adapter, while this gate guarantees stale callbacks cannot mutate state.
public final class WorkspaceOperationGate: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.prakharp.devspace.operations")
    private let lock = NSLock()
    private var generation: UInt64 = 0

    public init() {}

    public func cancelAll() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    public func submit<T>(
        operation: @escaping () throws -> T,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        lock.lock()
        let submittedGeneration = generation
        lock.unlock()

        queue.async { [weak self] in
            guard let self, self.isCurrent(submittedGeneration) else { return }
            let result = Result { try operation() }
            guard self.isCurrent(submittedGeneration) else { return }
            DispatchQueue.main.async { [weak self] in
                // Cancellation can happen after the worker finishes but before
                // its result reaches the controller's serialized event queue.
                guard let self, self.isCurrent(submittedGeneration) else { return }
                completion(result)
            }
        }
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == candidate
    }
}
