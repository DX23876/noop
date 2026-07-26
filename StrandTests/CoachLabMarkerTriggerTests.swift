import XCTest
@testable import Strand

/// Pins T3.7 of Etappe T: `log_lab_marker` was the one write tool without any "call it when…" trigger
/// clause in its description — every other log_* tool has one (`logCaffeine`, `logJournal`), telling the
/// model WHEN to reach for it, not just what it does once called.
final class CoachLabMarkerTriggerTests: XCTestCase {

    func testLogLabMarkerDescriptionHasATriggerClause() {
        let description = CoachTool.logLabMarker.description
        XCTAssertTrue(description.contains("Call it when"), "got: \(description)")
    }
}
