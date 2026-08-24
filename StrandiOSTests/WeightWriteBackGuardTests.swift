import XCTest
@testable import NOOP_Staging

/// `HealthKitBridge.shouldWriteProfileWeight` — the ping-pong guard on the profile-weight write-back.
///
/// Two echoes have to be rejected and they arrive from opposite directions, which is why each arm is
/// tested on its own: with both references set, a bug that ignores one of them still passes any test
/// that only ever exercises the other.
final class WeightWriteBackGuardTests: XCTestCase {

    // MARK: - The write that must happen

    /// A genuine edit of the profile field is the ONE change that belongs in Health.
    func testGenuineEditIsWritten() {
        XCTAssertTrue(HealthKitBridge.shouldWriteProfileWeight(
            78.0, lastImported: 82.4, lastSelfWritten: 82.4))
    }

    /// First install: nothing imported, nothing written yet. A nil reference cannot be an echo of
    /// anything, so it must not suppress the write — otherwise the very first weight never syncs.
    func testFirstEverValueIsWritten() {
        XCTAssertTrue(HealthKitBridge.shouldWriteProfileWeight(
            78.0, lastImported: nil, lastSelfWritten: nil))
    }

    // MARK: - The echoes that must not

    /// "Health always wins" set the profile from a Health reading; that fires the same publisher.
    func testHealthImportEchoIsSuppressed() {
        XCTAssertFalse(HealthKitBridge.shouldWriteProfileWeight(
            82.4, lastImported: 82.4, lastSelfWritten: nil))
    }

    /// A weigh-in logged in NOOP writes itself to Health under its OWN day and then updates the
    /// profile. Without this arm that echo writes a SECOND sample dated TODAY — so entering last
    /// Tuesday's weigh-in would also plant today's weight in Health. This is the regression the
    /// v43 weight history introduced and the reason the second reference exists.
    func testNoopOwnWeighInEchoIsSuppressed() {
        XCTAssertFalse(HealthKitBridge.shouldWriteProfileWeight(
            79.9, lastImported: 82.4, lastSelfWritten: 79.9))
    }

    // MARK: - The tolerance

    /// A round-trip reproduces the value exactly, but floating-point and unit conversion can shave a
    /// few grams off it. Anything inside the tolerance is still an echo.
    func testValueWithinToleranceIsStillAnEcho() {
        let nudged = 79.9 + HealthKitBridge.weightEchoToleranceKg / 2
        XCTAssertFalse(HealthKitBridge.shouldWriteProfileWeight(
            nudged, lastImported: nil, lastSelfWritten: 79.9))
    }

    /// …and a real edit just outside it is not. 100 g is a change a person can actually make.
    func testValueOutsideToleranceIsAnEdit() {
        let edited = 79.9 + HealthKitBridge.weightEchoToleranceKg * 2
        XCTAssertTrue(HealthKitBridge.shouldWriteProfileWeight(
            edited, lastImported: nil, lastSelfWritten: 79.9))
    }

    /// The guard is symmetric: an echo is an echo whether the new value sits above or below it.
    func testEchoIsDetectedInBothDirections() {
        XCTAssertFalse(HealthKitBridge.shouldWriteProfileWeight(
            79.88, lastImported: nil, lastSelfWritten: 79.9))
        XCTAssertFalse(HealthKitBridge.shouldWriteProfileWeight(
            79.92, lastImported: nil, lastSelfWritten: 79.9))
    }
}
