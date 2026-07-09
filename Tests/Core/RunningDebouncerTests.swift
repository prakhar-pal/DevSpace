import XCTest
@testable import DevSpaceCore

final class RunningDebouncerTests: XCTestCase {
    private func running(_ id: String) -> [String: Result<WorkspaceStatus, DevpodError>] {
        [id: .success(WorkspaceStatus(id: id, state: "Running"))]
    }

    private func stopped(_ id: String) -> [String: Result<WorkspaceStatus, DevpodError>] {
        [id: .success(WorkspaceStatus(id: id, state: "Stopped"))]
    }

    /// State after the filter, as Poller.merge would see it: a dropped entry
    /// is nil (merge renders it as the non-definitive "Loading").
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
        // First Running after Stopped is held back — the entry is dropped
        // (renders as Loading), NOT rewritten to Stopped: a fabricated Stopped
        // would close the terminal a self-initiated `devpod up` just opened.
        XCTAssertNil(d.filter(running("a"))["a"])
        // …the second consecutive Running is accepted.
        XCTAssertEqual(state(d.filter(running("a")), "a"), "Running")
    }

    func testSingleRunningBlipAfterStopIsFullySuppressed() {
        // The k8s teardown flap: Stopped, one false Running, Stopped again.
        var d = RunningDebouncer()
        _ = d.filter(stopped("a"))
        XCTAssertNil(d.filter(running("a"))["a"]) // blip held
        XCTAssertEqual(state(d.filter(stopped("a")), "a"), "Stopped")
        // A later real start still needs two fetches (streak was reset).
        XCTAssertNil(d.filter(running("a"))["a"])
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
        XCTAssertNil(d.filter(running("a"))["a"]) // held
        _ = d.filter(["a": .success(WorkspaceStatus(id: "a", state: "Busy"))])
        // The Busy broke the consecutive-Running streak: hold again.
        XCTAssertNil(d.filter(running("a"))["a"])
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
        XCTAssertNil(out["a"])                     // a: held (was Stopped)
        XCTAssertEqual(state(out, "b"), "Running") // b: unaffected
    }
}
