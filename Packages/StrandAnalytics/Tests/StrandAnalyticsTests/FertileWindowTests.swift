import XCTest
@testable import StrandAnalytics

final class FertileWindowTests: XCTestCase {

    func testNeedsThreePastRises() {
        XCTAssertNil(FertileWindow.estimate(pastRiseDays: [14, 15], currentRiseDay: nil, positiveTestDay: nil))
        XCTAssertNotNil(FertileWindow.estimate(pastRiseDays: [14, 15, 13], currentRiseDay: nil, positiveTestDay: nil))
    }

    func testHistoryWindowSpansTheSpreadOfRises() {
        // Rises on days 13 to 16: ovulation 12 to 15, so fertile from 12 − 5 = 7 to 15.
        let e = FertileWindow.estimate(pastRiseDays: [14, 13, 16, 14], currentRiseDay: nil, positiveTestDay: nil)!
        XCTAssertEqual(e.firstDay, 7)
        XCTAssertEqual(e.lastDay, 15)
        XCTAssertEqual(e.basis, .history)
        XCTAssertEqual(e.typicalRiseDay, 14)
    }

    func testRegularHistoryGivesANarrowerWindowThanAnIrregularOne() {
        let regular = FertileWindow.estimate(pastRiseDays: [14, 14, 14], currentRiseDay: nil, positiveTestDay: nil)!
        let irregular = FertileWindow.estimate(pastRiseDays: [12, 18, 15], currentRiseDay: nil, positiveTestDay: nil)!
        XCTAssertEqual(regular.length, 6)
        XCTAssertGreaterThan(irregular.length, regular.length)
    }

    func testPositiveTestNarrowsTheWindow() {
        let e = FertileWindow.estimate(pastRiseDays: [14, 13, 16], currentRiseDay: nil, positiveTestDay: 12)!
        XCTAssertEqual(e.basis, .ovulationTest)
        XCTAssertEqual(e.firstDay, 12)
        XCTAssertEqual(e.lastDay, 13)
    }

    func testPositiveTestWorksWithoutHistory() {
        XCTAssertEqual(FertileWindow.estimate(pastRiseDays: [], currentRiseDay: nil, positiveTestDay: 11)?.basis, .ovulationTest)
    }

    func testRiseThisCycleClosesTheWindow() {
        let e = FertileWindow.estimate(pastRiseDays: [14, 13, 16], currentRiseDay: 15, positiveTestDay: nil)!
        XCTAssertEqual(e.basis, .confirmedByRise)
        XCTAssertEqual(e.firstDay, 9)
        XCTAssertEqual(e.lastDay, 14)
        XCTAssertEqual(FertileWindow.status(e, cycleDay: 12), .over)
    }

    func testStatusAcrossTheCycle() {
        let e = FertileWindow.estimate(pastRiseDays: [14, 14, 14], currentRiseDay: nil, positiveTestDay: nil)!
        XCTAssertEqual(e.firstDay, 8)
        XCTAssertEqual(FertileWindow.status(e, cycleDay: 2), .before(daysUntil: 6))
        XCTAssertEqual(FertileWindow.status(e, cycleDay: 10), .during(day: 3, of: 6))
        XCTAssertEqual(FertileWindow.status(e, cycleDay: 14), .over)
    }

    func testImplausibleRiseDaysAreIgnored() {
        XCTAssertNil(FertileWindow.estimate(pastRiseDays: [3, 40, 14, 15], currentRiseDay: nil, positiveTestDay: nil))
    }
}
