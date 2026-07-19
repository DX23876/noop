import XCTest
@testable import Strand

/// `StrainTargetNotifier.StrainTargetPolicy` — the pure once-per-day crossing gate + copy behind the
/// #593 optimal-strain-reached nudge. Mirrors the Android `StrainTargetPolicyTest` byte-for-byte (same
/// fixtures, same expectations). No notification/UserDefaults runtime needed here. Contract: fire at
/// most once per day, only when strain has genuinely reached a KNOWN target, never on a guessed one.
final class StrainTargetPolicyTests: XCTestCase {
    private typealias Policy = StrainTargetNotifier.StrainTargetPolicy

    func testFiresWhenEnabledStrainReachedTargetAndNotYetToday() {
        XCTAssertTrue(Policy.shouldNotify(
            enabled: true, dayStrain: 14.0, target: 14.0, lastNotifiedDay: "2026-07-17", today: "2026-07-18"))
        // Overshooting the target still fires (>= gate), once.
        XCTAssertTrue(Policy.shouldNotify(
            enabled: true, dayStrain: 16.2, target: 14.0, lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedWhenDisabled() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: false, dayStrain: 18.0, target: 14.0, lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedBeforeTargetIsReached() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, dayStrain: 13.9, target: 14.0, lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedWhenAlreadyFiredToday() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, dayStrain: 15.0, target: 14.0, lastNotifiedDay: "2026-07-18", today: "2026-07-18"))
    }

    func testSuppressedWhenTargetUnknownCalibrating() {
        // nil recovery ⇒ no optimal band ⇒ nil target ⇒ never fire (never guess a target).
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, dayStrain: 18.0, target: nil, lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedWhenNoStrainYet() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, dayStrain: nil, target: 14.0, lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testCopyUsesNoopWordingAndTheTarget() {
        let copy = Policy.copy(target: 14)
        // NOOP's own copy — must NOT reproduce WHOOP's decompiled strings.
        XCTAssertTrue(copy.title.contains("Optimal strain"))
        XCTAssertFalse(copy.title.contains("Target Strain Reached"))
        XCTAssertTrue(copy.body.contains("14"))
        XCTAssertFalse(copy.body.contains("for this activity"))
    }
}
