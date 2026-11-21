import XCTest
import WhoopStore
@testable import Strand

/// "Duplicate as manual" must never take the original's key (device, start, sport): saving the copy unchanged
/// replaced an import stored under the strap's id, and deleting the copy then lost the session (2026-11-22).
final class WorkoutManualCopyTests: XCTestCase {
    func testCopyStartsAfterTheOriginalAndKeepsItsLength() {
        let imported = WorkoutRow(startTs: 1_000, endTs: 4_000, sport: "Rowing", source: "whoop", durationS: 3_000,
                                  energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                                  zonesJSON: nil, notes: nil, steps: nil)
        let copy = WorkoutsView.manualCopy(of: imported)
        XCTAssertEqual(copy.source, "manual")
        XCTAssertNotEqual(copy.startTs, imported.startTs)
        XCTAssertEqual(copy.endTs - copy.startTs, imported.endTs - imported.startTs)
    }
}
