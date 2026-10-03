import XCTest
@testable import Strand

final class LiquidMomentumRefreshTests: XCTestCase {
    /// Replays task(id:) invalidation with an asynchronous snapshot: selection changes first,
    /// then the selected day's data commits. Both transitions must be observable by the feed task.
    func testDaySwipeAndReturnRebuildAfterSnapshotCommit() {
        var offset = 0
        var revision = 1
        var snapshotCharge = 80
        var displayedCharge = 80
        func key() -> TodayView.MomentumKey {
            TodayView.MomentumKey(refreshSeq: 1, dayOffset: offset, hour: 8,
                                  lastShownKind: "recoveryState", snoozed: "",
                                  goalsUpdatedAt: nil, statusState: "active",
                                  loadedRevision: revision)
        }
        var previous = key()
        for (selection, charge) in [(1, 51), (0, 80), (1, 51), (0, 80)] {
            offset = selection
            let waiting = key()
            XCTAssertNotEqual(previous, waiting)
            previous = waiting
            snapshotCharge = charge
            revision += 1
            if key() != previous { displayedCharge = snapshotCharge; previous = key() }
            XCTAssertEqual(displayedCharge, charge, "Momentum must follow the committed day's hero")
        }
    }

    func testSameDayRefreshInvalidatesWithoutChangingSelectionOrRepositorySequence() {
        let before = TodayView.MomentumKey(refreshSeq: 7, dayOffset: 0, hour: 8,
                                           lastShownKind: "recoveryState", snoozed: "",
                                           goalsUpdatedAt: nil, statusState: "active", loadedRevision: 1)
        var after = before
        after.loadedRevision = 2
        XCTAssertNotEqual(before, after)
    }
}
