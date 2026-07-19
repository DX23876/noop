import XCTest
@testable import OuraProtocol

/// Live wear/charge inference for the "On wrist / Off wrist" indicator. The ring emits no dedicated worn
/// event in NOOP's captures, so wear is inferred from a LIVE-HR beat (a finger), a silent stream past a
/// grace window (removed), and the ring's own "chg. detected"/"chg. stopped" STATE strings (charging).
final class OuraWearTests: XCTestCase {

    private func state(_ rt: UInt32, _ text: String) -> OuraState {
        OuraState(ringTimestamp: rt, stateCode: 0, text: text)
    }

    // MARK: - STATE-string semantics

    func testChargerStartStopStringMatching() {
        XCTAssertTrue(OuraWear.isChargerStart(state(1, "chg. detected")))
        XCTAssertTrue(OuraWear.isChargerStop(state(1, "chg. stopped")))
        // not a charger line (these real strings must never be read as charge transitions)
        XCTAssertFalse(OuraWear.isChargerStart(state(1, "hr enable")))
        XCTAssertFalse(OuraWear.isChargerStop(state(1, "orientation")))
        XCTAssertFalse(OuraWear.isChargerStart(state(1, "fea off")))
        XCTAssertFalse(OuraWear.isChargerStop(state(1, "motion det")))
        // a nil / empty text never matches
        XCTAssertFalse(OuraWear.isChargerStart(OuraState(ringTimestamp: 1, stateCode: 8, text: nil)))
    }

    // MARK: - Live tracker

    func testLiveTrackerPulseMeansWorn() {
        let t = OuraWearTracker()
        XCTAssertEqual(t.current, .unknown)
        t.note(state: state(1, "chg. detected"))
        XCTAssertEqual(t.current, .charging)
        t.note(state: state(2, "chg. stopped"))
        XCTAssertEqual(t.current, .off)
        t.notePulse()                                  // a live beat can only come from a finger
        XCTAssertEqual(t.current, .worn)
        t.note(state: state(3, "chg. detected"))       // back on the charger
        XCTAssertEqual(t.current, .charging)
        t.reset()
        XCTAssertEqual(t.current, .unknown)
    }

    func testLivePulseTimeoutDowngradesWornToOff() {
        // The ring emits no "removed" event; a silent live-HR stream is the only signal. A timeout
        // downgrades worn -> off, but must NOT override charging or fabricate a not-worn from unknown.
        let t = OuraWearTracker()
        t.noteLivePulseTimeout()
        XCTAssertEqual(t.current, .unknown)            // no evidence yet -> unchanged
        t.notePulse()
        XCTAssertEqual(t.current, .worn)
        t.noteLivePulseTimeout()                       // stream went quiet -> removed
        XCTAssertEqual(t.current, .off)
        // charging is authoritative: a timeout never flips it to off.
        t.note(state: state(9, "chg. detected"))
        XCTAssertEqual(t.current, .charging)
        t.noteLivePulseTimeout()
        XCTAssertEqual(t.current, .charging)
    }
}
