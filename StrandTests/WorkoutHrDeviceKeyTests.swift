import XCTest
@testable import Strand

/// #510: `reconcileWorkoutHrWithTrace` used to read every workout's HR window under the Repository's single
/// active `deviceId`, so a bout auto-detected on a SECOND WHOOP (its `hrSample` rows banked under that strap)
/// read the active strap's empty window and its Avg HR / Effort went un-reconciled. `Repository.workoutHrDeviceId`
/// now resolves the read key per row from the workout's own `source`. Kotlin twin: `WorkoutHrDeviceKeyTest`.
///
/// NB the Swift read-model `WorkoutRow` carries no `deviceId`, so only DETECTED rows (whose `source` IS their
/// computed strap id "<base>-noop") can key on their own strap here; MANUAL/IMPORTED rows reconcile against the
/// active strap. This mirrors the Kotlin fix for the dominant (detected) multi-WHOOP case.
final class WorkoutHrDeviceKeyTests: XCTestCase {

    /// A bout detected on a 2nd WHOOP lives under "whoop-aabbcc-noop"; its HR is banked under "whoop-aabbcc".
    /// The active strap being something else must NOT redirect the read to an empty window.
    func testDetectedReadsItsOwnBaseStrap_notActive() {
        XCTAssertEqual(
            Repository.workoutHrDeviceId(source: "whoop-aabbcc-noop", activeStrapId: "my-whoop"),
            "whoop-aabbcc")
    }

    /// Single-WHOOP: the canonical detected id strips to the active id, so the read is byte-identical to the
    /// old `self.deviceId` behaviour.
    func testDetectedCanonicalIsByteIdenticalToActive() {
        XCTAssertEqual(
            Repository.workoutHrDeviceId(source: "my-whoop-noop", activeStrapId: "my-whoop"),
            "my-whoop")
    }

    /// Manual rows carry no strap id in `source`, so they reconcile against the active strap (the documented
    /// display-only divergence from the Kotlin twin, which keys manual rows on their stored deviceId).
    func testManualReadsActiveStrap() {
        XCTAssertEqual(
            Repository.workoutHrDeviceId(source: "manual", activeStrapId: "whoop-aabbcc"),
            "whoop-aabbcc")
    }

    /// Imported rows (Apple / activity file / lifting / WHOOP CSV) reconcile against the active strap — the
    /// worn-strap fill (#77) is unchanged. Includes the legacy `apple_health` spelling and the CSV `my-whoop`
    /// source (contains "whoop" but not "-noop", so it classifies non-detected and is NOT stripped).
    func testImportedReadsActiveStrap() {
        for src in ["apple-health", "apple_health", "activity-file", "lifting", "my-whoop", "Health Connect"] {
            XCTAssertEqual(
                Repository.workoutHrDeviceId(source: src, activeStrapId: "whoop-aabbcc"),
                "whoop-aabbcc",
                "imported source \(src) should reconcile against the active strap")
        }
    }
}
