import XCTest
@testable import DevSpaceCore

final class WorkspaceOperationGateTests: XCTestCase {
    func testCompletionRunsOnControllerMainQueue() {
        let gate = WorkspaceOperationGate()
        let completed = expectation(description: "main-queue completion")
        gate.submit(operation: { "value" }) { result in
            XCTAssertTrue(Thread.isMainThread, "controller effects must not run on the operation worker")
            XCTAssertEqual(try? result.get(), "value")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testCancellationSuppressesLateCompletion() {
        let gate = WorkspaceOperationGate()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = expectation(description: "completion")
        completed.isInverted = true

        gate.submit(
            operation: {
                started.signal()
                release.wait()
                return "late"
            },
            completion: { _ in completed.fulfill() }
        )
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

        gate.cancelAll()
        release.signal()

        wait(for: [completed], timeout: 0.1)
    }

    func testCancellationBeforeMainQueueDeliverySuppressesCompletion() {
        let gate = WorkspaceOperationGate()
        let nextOperation = DispatchSemaphore(value: 0)
        let completed = expectation(description: "queued completion")
        completed.isInverted = true
        gate.submit(operation: { "late" }, completion: { _ in completed.fulfill() })
        gate.submit(operation: { nextOperation.signal() }, completion: { _ in })
        // The serial worker cannot start the second operation until the first
        // result has been queued. Blocking this thread keeps delivery pending.
        XCTAssertEqual(nextOperation.wait(timeout: .now() + 1), .success)
        gate.cancelAll()
        wait(for: [completed], timeout: 0.1)
    }

    func testOperationsRunInSubmissionOrder() {
        let gate = WorkspaceOperationGate()
        let completed = expectation(description: "both completions")
        completed.expectedFulfillmentCount = 2
        var results: [Int] = []
        let lock = NSLock()

        for value in [1, 2] {
            gate.submit(operation: { value }) { result in
                if case let .success(value) = result {
                    lock.lock()
                    results.append(value)
                    lock.unlock()
                }
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(results, [1, 2])
    }
}
