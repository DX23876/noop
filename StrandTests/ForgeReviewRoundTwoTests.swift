import XCTest
import StrandCore
@testable import Strand

/// The second design review of the new design (2026-11-07) fixed places where two cards told the same fact
/// differently. These pin the shared pieces those cards now read.
final class ForgeReviewRoundTwoTests: XCTestCase {

    // MARK: Charge reasons: the usual range

    func testMiddleHalfIsTheQuartilesAndNeedsSevenNights() {
        XCTAssertNil(ForgeToday.middleHalf([1, 2, 3, 4, 5, 6]))
        let q = ForgeToday.middleHalf([9, 1, 5, 3, 7, 2, 8, 4, 6])
        XCTAssertEqual(q?.low, 3)
        XCTAssertEqual(q?.high, 7)
    }

    func testPlaceKeepsTheRangeAndAFarValueOnTheTrack() {
        let inside = ForgeToday.place(50, low: 46, high: 57)
        XCTAssertTrue(inside.band.contains(inside.position))
        XCTAssertGreaterThan(inside.band.lowerBound, 0)
        XCTAssertLessThan(inside.band.upperBound, 100)

        let far = ForgeToday.place(80, low: 46, high: 57)
        XCTAssertFalse(far.band.contains(far.position))
        XCTAssertGreaterThanOrEqual(far.position, 0)
        XCTAssertLessThanOrEqual(far.position, 100)
    }

    // MARK: Effort this week

    func testWeekMeanSkipsDaysWithoutAValue() {
        XCTAssertEqual(ForgeToday.weekMean([10, nil, 14, nil]), 12)
        XCTAssertNil(ForgeToday.weekMean([nil, nil]))
    }

    // MARK: What correlates

    func testAScoreIsNotCorrelatedWithItsOwnInputs() {
        XCTAssertTrue(MetricDetailView.isScoreAndInput("recovery", "hrv"))
        XCTAssertTrue(MetricDetailView.isScoreAndInput("hrv", "recovery"))
        XCTAssertTrue(MetricDetailView.isScoreAndInput("stress", "rhr"))
        XCTAssertFalse(MetricDetailView.isScoreAndInput("hrv", "steps"))
        XCTAssertFalse(MetricDetailView.isScoreAndInput("recovery", "steps"))
    }

    // MARK: Goals name their sport

    func testASportFilteredDistanceGoalNamesTheSport() {
        var goal = PeriodGoal(metric: .distance, period: .week, target: 30)
        goal.sportFilter = ["Cycling"]
        let name = GoalFormat.shortName(goal)
        XCTAssertTrue(name.hasPrefix(PeriodMetric.distance.label.localizedCatalogValue), name)
        XCTAssertTrue(name.contains(WorkoutSource.localizedDisplaySport("Cycling")), name)

        goal.sportFilter = []
        XCTAssertEqual(GoalFormat.shortName(goal), PeriodMetric.distance.label.localizedCatalogValue)
    }
}
