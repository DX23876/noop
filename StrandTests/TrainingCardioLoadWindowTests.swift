import XCTest
@testable import Strand

/// One physical bout is priced once. Two components the wearer has not ruled on yet stay separate on
/// purpose — that is the duplicate review — but they describe the same minutes of heart rate, so adding
/// both would double that day's Cardio Load until the review is answered.
final class TrainingCardioLoadWindowTests: XCTestCase {
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
}
