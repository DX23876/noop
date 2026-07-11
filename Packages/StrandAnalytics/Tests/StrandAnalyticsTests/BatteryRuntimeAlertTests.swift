import XCTest
@testable import StrandAnalytics

final class BatteryRuntimeAlertTests: XCTestCase {

    func testFiresAtThresholdAndArms() {
        let r = BatteryEstimator.runtimeAlert(remainingHours: 24, charging: false, alerted: false)
        XCTAssertTrue(r.fire)
        XCTAssertTrue(r.newAlerted)
    }

    func testAboveThresholdNoFire() {
        let r = BatteryEstimator.runtimeAlert(remainingHours: 25, charging: false, alerted: false)
        XCTAssertFalse(r.fire)
        XCTAssertFalse(r.newAlerted)
    }

    func testJitterInsideBandCannotRefire() {
        // Fired at 24h, estimate bounces 23 → 26 → 22: still armed-off, no second alert.
        var alerted = BatteryEstimator.runtimeAlert(remainingHours: 23, charging: nil, alerted: false).newAlerted
        XCTAssertTrue(alerted)
        for hours in [26.0, 22.0, 30.0, 24.0] {
            let r = BatteryEstimator.runtimeAlert(remainingHours: hours, charging: nil, alerted: alerted)
            XCTAssertFalse(r.fire, "re-fired at \(hours)h inside the hysteresis band")
            alerted = r.newAlerted
        }
    }

    func testRearmsOnGenuineRecoveryThenFiresNextCycle() {
        // Charge recovers the estimate past 36h → gate re-arms; the next drop to 24h fires again.
        var alerted = BatteryEstimator.runtimeAlert(remainingHours: 20, charging: nil, alerted: false).newAlerted
        let recovered = BatteryEstimator.runtimeAlert(remainingHours: 100, charging: nil, alerted: alerted)
        XCTAssertFalse(recovered.fire)
        XCTAssertFalse(recovered.newAlerted)
        alerted = recovered.newAlerted
        XCTAssertTrue(BatteryEstimator.runtimeAlert(remainingHours: 24, charging: nil, alerted: alerted).fire)
    }

    func testConfirmedChargingSuppressesButUnknownFires() {
        XCTAssertFalse(BatteryEstimator.runtimeAlert(remainingHours: 10, charging: true, alerted: false).fire)
        XCTAssertTrue(BatteryEstimator.runtimeAlert(remainingHours: 10, charging: nil, alerted: false).fire)
    }

    func testChargingSuppressionDoesNotArmGate() {
        // Suppressed while charging must NOT consume the once-per-cycle gate: unplug below the
        // threshold and the alert should still fire.
        let plugged = BatteryEstimator.runtimeAlert(remainingHours: 10, charging: true, alerted: false)
        XCTAssertFalse(plugged.newAlerted)
        XCTAssertTrue(BatteryEstimator.runtimeAlert(remainingHours: 10, charging: false,
                                                    alerted: plugged.newAlerted).fire)
    }

    func testRearmBoundaryIsInclusive() {
        XCTAssertFalse(BatteryEstimator.runtimeAlert(remainingHours: 36, charging: nil, alerted: true).newAlerted)
        XCTAssertTrue(BatteryEstimator.runtimeAlert(remainingHours: 35.9, charging: nil, alerted: true).newAlerted)
    }
}
