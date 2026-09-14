import XCTest
import WhoopStore
@testable import Strand

/// One physical bout is priced once. Two components the wearer has not ruled on yet stay separate on
/// purpose — that is the duplicate review — but they describe the same minutes of heart rate, so adding
/// both would double that day's Cardio Load until the review is answered.
final class TrainingCardioLoadWindowTests: XCTestCase {
    private func session(id: String = "canonical", source: String = "whoop",
                         start: Int = 1_000) -> UnifiedTrainingSession {
        let row = WorkoutRow(startTs: start, endTs: start + 3_600, sport: "Running",
                             source: source, durationS: 3_600, energyKcal: nil,
                             avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                             zonesJSON: nil, notes: nil, steps: nil)
        return UnifiedTrainingSession(id: id, kind: .endurance, row: row,
                                      components: [TrainingSessionComponent(id: "component", row: row,
                                                                            metadata: nil)],
                                      fusionOrigin: "automatic")
    }

    func testUnresolvedTwinsOfOneBoutAreTheSameMinutes() {
        XCTAssertTrue(Repository.describesSameMinutes((start: 1_000, end: 4_600),
                                                      (start: 1_030, end: 4_570)))
    }

    func testBackToBackSessionsAreTwoBouts() {
        XCTAssertFalse(Repository.describesSameMinutes((start: 1_000, end: 4_600),
                                                       (start: 4_600, end: 8_200)))
    }

    /// A cooldown that runs a few minutes into the next session is not that session: only an overlap of
    /// more than half the shorter window counts, the same rule cross-source dedup applies.
    func testAShortOverlapAtTheSeamIsNotTheSameMinutes() {
        XCTAssertFalse(Repository.describesSameMinutes((start: 0, end: 3_600),
                                                       (start: 3_000, end: 6_600)))
    }

    func testAShortSessionFullyInsideALongOneIsTheSameMinutes() {
        XCTAssertTrue(Repository.describesSameMinutes((start: 0, end: 7_200),
                                                      (start: 1_800, end: 3_600)))
    }

    func testMemoKeyChangesForEveryScientificInput() {
        let base = Repository.cardioLoadMemoKey(session: session(), maxHR: 190, dataRevision: 4)
        XCTAssertNotEqual(base, Repository.cardioLoadMemoKey(session: session(), maxHR: 191,
                                                             dataRevision: 4))
        XCTAssertNotEqual(base, Repository.cardioLoadMemoKey(session: session(), maxHR: 190,
                                                             dataRevision: 5))
        XCTAssertNotEqual(base, Repository.cardioLoadMemoKey(session: session(id: "new-canonical"),
                                                             maxHR: 190, dataRevision: 4))
        XCTAssertNotEqual(base, Repository.cardioLoadMemoKey(session: session(source: "apple-health"),
                                                             maxHR: 190, dataRevision: 4))
        XCTAssertNotEqual(base, Repository.cardioLoadMemoKey(session: session(), maxHR: 190,
                                                             dataRevision: 4, recipeVersion: 99))
    }
}
