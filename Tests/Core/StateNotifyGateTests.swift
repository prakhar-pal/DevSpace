import XCTest
@testable import DevSpaceCore

final class StateNotifyGateTests: XCTestCase {
    private func ws(_ id: String, _ state: String) -> WorkspaceView {
        WorkspaceView(id: id, provider: "k8s", source: "src", lastUsed: "", state: state, error: nil)
    }

    func testFirstPollBaselinesSilently() {
        var g = StateNotifyGate()
        XCTAssertEqual(g.observe([ws("a", "Running"), ws("b", "Stopped")]).count, 0)
    }

    func testStoppedTransitionNotifiesImmediately() {
        var g = StateNotifyGate()
        _ = g.observe([ws("a", "Running")])
        let events = g.observe([ws("a", "Stopped")])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, "a")
        XCTAssertEqual(events[0].event, "stopped")
    }

    func testStartedWaitsForSSHConfirm() {
        var g = StateNotifyGate()
        _ = g.observe([ws("a", "Stopped")])
        // Poller sees Running, but we haven't SSH'd in — no event yet.
        XCTAssertEqual(g.observe([ws("a", "Running")]).count, 0)
        // SSH round-trip succeeded — the deferred "started" fires now.
        XCTAssertTrue(g.confirmSSH("a"))
        // Confirming again must not re-fire.
        XCTAssertFalse(g.confirmSSH("a"))
    }

    func testConfirmBeforePollObservationFiresOnObservation() {
        // The app opens SSH optimistically when `devpod up` finishes, so the
        // confirm can land BEFORE the poller observes Stopped→Running.
        var g = StateNotifyGate()
        _ = g.observe([ws("a", "Stopped")])
        XCTAssertFalse(g.confirmSSH("a")) // nothing pending yet
        let events = g.observe([ws("a", "Running")])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "started")
    }

    func testTransientBlipsNeitherFireNorSwallow() {
        var g = StateNotifyGate()
        _ = g.observe([ws("a", "Running")])
        // Busy/Loading/Unknown are not definitive — ignored entirely.
        XCTAssertEqual(g.observe([ws("a", "Busy")]).count, 0)
        XCTAssertEqual(g.observe([ws("a", "Stopped")]).count, 1)
    }

    func testStopClearsPendingAndConfirmed() {
        var g = StateNotifyGate()
        _ = g.observe([ws("a", "Stopped")])
        _ = g.observe([ws("a", "Running")]) // pending, unconfirmed
        _ = g.observe([ws("a", "Stopped")]) // stop clears pending + confirmed
        XCTAssertFalse(g.confirmSSH("a"))   // stale confirm: nothing pending
        // Next start must wait for a FRESH ssh confirm despite the old one...
        // (the stale confirm above re-marked it; a stop must have cleared the
        // one from before the stop)
        var g2 = StateNotifyGate()
        _ = g2.observe([ws("a", "Stopped")])
        XCTAssertFalse(g2.confirmSSH("a"))
        _ = g2.observe([ws("a", "Running")]) // fires (confirmed pre-observation)
        _ = g2.observe([ws("a", "Stopped")]) // stopped event; clears confirmed
        XCTAssertEqual(g2.observe([ws("a", "Running")]).count, 0) // waits again
    }

    func testResetRebaselinesSilently() {
        var g = StateNotifyGate()
        _ = g.observe([ws("a", "Stopped")])
        _ = g.observe([ws("a", "Running")]) // pending started
        g.reset("a") // hidden-pod select/unhide: re-baseline silently
        XCTAssertFalse(g.confirmSSH("a")) // pending was dropped
        XCTAssertEqual(g.observe([ws("a", "Stopped")]).count, 0) // baseline, no event
    }

    func testReleasePendingFiresStartedForUnconnectedPods() {
        // Under the no-auto-wake policy the app doesn't SSH into externally
        // started pods, so their pending "started" can never be SSH-confirmed —
        // releasePending fires them on the (debounced) observation instead,
        // while pods the app IS connecting to stay pending for confirmSSH.
        var g = StateNotifyGate()
        _ = g.observe([ws("a", "Stopped"), ws("b", "Stopped")])
        _ = g.observe([ws("a", "Running"), ws("b", "Running")]) // both pending
        XCTAssertEqual(g.releasePending(notIn: ["b"]), ["a"])
        XCTAssertFalse(g.confirmSSH("a")) // already released — must not re-fire
        XCTAssertTrue(g.confirmSSH("b"))  // still pending; ssh confirm fires it
        XCTAssertEqual(g.releasePending(notIn: []), []) // nothing left
    }

    func testPodFirstSeenMidSessionBaselinesSilently() {
        var g = StateNotifyGate()
        _ = g.observe([ws("a", "Running")])
        XCTAssertEqual(g.observe([ws("a", "Running"), ws("b", "Running")]).count, 0)
    }
}
