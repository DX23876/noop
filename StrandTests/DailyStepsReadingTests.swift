import XCTest
@testable import Strand

/// Pins the day's step figure to ONE rule.
///
/// Overview shipped with a shorter version of TodayView's rule — strap counter, then Apple Health, and
/// nothing after that. A WHOOP 4.0 sends no step counter, so on a day with no same-day Apple row the tile
/// had nothing to show, while Today showed the on-device estimate for the same day. The rule (#843/#813)
/// is now one function; these tests are what keep a third, shorter copy from appearing.
final class DailyStepsReadingTests: XCTestCase {

    func testStrapCounterWinsOverEveryOtherSource() {
        let reading = DailyStepsReading.resolve(strapSteps: 8_100, appleSteps: 7_400, estimatedSteps: 6_000)
        XCTAssertEqual(reading, .measured(8_100))
        XCTAssertFalse(reading?.isEstimated ?? true)
    }

    func testAppleHealthFillsInForAStrapThatCannotCount() {
        XCTAssertEqual(DailyStepsReading.resolve(strapSteps: nil, appleSteps: 7_400, estimatedSteps: 6_000),
                       .measured(7_400))
    }

    /// The gap a WHOOP 4.0 user would otherwise see as "—". The estimate fills it, and is marked.
    func testEstimateIsUsedLastAndIsMarkedAsAnEstimate() {
        let reading = DailyStepsReading.resolve(strapSteps: nil, appleSteps: nil, estimatedSteps: 6_000)
        XCTAssertEqual(reading, .estimated(6_000))
        XCTAssertTrue(reading?.isEstimated ?? false)
        XCTAssertEqual(reading?.steps, 6_000)
    }

    /// No source for THIS day means no number. The rule must not reach for the newest row it has — that
    /// is the stale-import bug the rule exists to prevent, and it is the caller's job to pass same-day
    /// values, so the honest answer here is nil rather than a fabricated one.
    func testNoSameDaySourceMeansNoReading() {
        XCTAssertNil(DailyStepsReading.resolve(strapSteps: nil, appleSteps: nil, estimatedSteps: nil))
    }

    /// A real zero is a real answer — a day with no steps recorded by a strap that DOES count is 0, not
    /// "fall through to the estimate".
    func testAMeasuredZeroIsNotTreatedAsMissing() {
        XCTAssertEqual(DailyStepsReading.resolve(strapSteps: 0, appleSteps: nil, estimatedSteps: 6_000),
                       .measured(0))
        XCTAssertEqual(DailyStepsReading.resolve(strapSteps: nil, appleSteps: 0, estimatedSteps: 6_000),
                       .measured(0))
    }
}
