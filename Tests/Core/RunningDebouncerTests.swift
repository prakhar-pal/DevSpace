import XCTest
@testable import DevSpaceCore

final class RunningDebouncerTests: XCTestCase {
    private func running(_ id: String) -> [String: Result<WorkspaceStatus, DevpodError>] {
        [id: .success(WorkspaceStatus(id: id, state: "Running"))]
    }

    private func stopped(_ id: String) -> [String: Result<WorkspaceStatus, DevpodError>] {
        [id: .success(WorkspaceStatus(id: id, state: "Stopped"))]
    }

    private func state(_ out: [String: Result<WorkspaceStatus, DevpodError>], _ id: String) -> String? {
        if case let .success(s) = out[id] { return s.state }
        return nil
    }

    func testFirstSightingRunningIsAcceptedImmediately() {
        var d = RunningDebouncer()
        XCTAssertEqual(state(d.filter(running("a")), "a"), "Running")
    }

    func testStoppedToRunningNeedsTwoConsecutiveFetches() {
        var d = RunningDebouncer()
        _ = d.filter(stopped("a"))
        // First Running after Stopped is held back as Stopped…
        XCTAssertEqual(state(d.filter(running("a")), "a"), "Stopped")
        // …the second consecutive Running is accepted.
        XCTAssertEqual(state(d.filter(running("a")), "a"), "Running")
    }

    func testSingleRunningBlipAfterStopIsFullySuppressed() {
        // The k8s teardown flap: Stopped, one false Running, Stopped again.
        var d = RunningDebouncer()
        _ = d.filter(stopped("a"))
        XCTAssertEqual(state(d.filter(running("a")), "a"), "Stopped") // blip held
        XCTAssertEqual(state(d.filter(stopped("a")), "a"), "Stopped")
        // A later real start still needs two fetches (streak was reset).
        XCTAssertEqual(state(d.filter(running("a")), "a"), "Stopped")
        XCTAssertEqual(state(d.filter(running("a")), "a"), "Running")
    }

    func testRunningToStoppedIsImmediate() {
        // Stops are never debounced — closing panes promptly matters.
        var d = RunningDebouncer()
        _ = d.filter(running("a"))
        XCTAssertEqual(state(d.filter(stopped("a")), "a"), "Stopped")
    }

    func testNonDefinitiveStateBreaksTheRunningStreak() {
        var d = RunningDebouncer()
        _ = d.filter(stopped("a"))
        XCTAssertEqual(state(d.filter(running("a")), "a"), "Stopped") // held
        _ = d.filter(["a": .success(WorkspaceStatus(id: "a", state: "Busy"))])
        // The Busy broke the consecutive-Running streak: hold again.
        XCTAssertEqual(state(d.filter(running("a")), "a"), "Stopped")
        XCTAssertEqual(state(d.filter(running("a")), "a"), "Running")
    }

    func testFailuresAndOtherStatesPassThroughUntouched() {
        var d = RunningDebouncer()
        let err: [String: Result<WorkspaceStatus, DevpodError>] = ["a": .failure(DevpodError("boom"))]
        if case .failure = d.filter(err)["a"] {} else { XCTFail("failure must pass through") }
        _ = d.filter(stopped("b"))
        XCTAssertEqual(state(d.filter(["b": .success(WorkspaceStatus(id: "b", state: "Busy"))]), "b"), "Busy")
    }

    func testIndependentPods() {
        var d = RunningDebouncer()
        _ = d.filter(stopped("a").merging(running("b")) { a, _ in a })
        let out = d.filter(running("a").merging(running("b")) { a, _ in a })
        XCTAssertEqual(state(out, "a"), "Stopped") // a: held (was Stopped)
        XCTAssertEqual(state(out, "b"), "Running") // b: unaffected
    }
}
