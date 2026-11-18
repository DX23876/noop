import XCTest
@testable import NoopCore

/// The one bundle both phones read when a tile is given more room (`MeasureFacts`). The cases here are the
/// ones the tiles actually depend on, and the ones where a careless reading would quietly lie.
final class MeasureFactsTests: XCTestCase {

    private func points(_ pairs: [(String, Double)]) -> [MeasureFacts.Point] {
        pairs.map { MeasureFacts.Point(day: $0.0, value: $0.1) }
    }

    /// Steps: the week's total and its daily average are what the two-column tile adds.
    func testTheWeekIsTheSevenDaysEndingToday() {
        let p = points([("2026-11-12", 1000), ("2026-11-13", 2000), ("2026-11-14", 3000),
                        ("2026-11-15", 4000), ("2026-11-16", 5000), ("2026-11-17", 6000),
                        ("2026-11-18", 7000)])
        let f = MeasureFacts.read(points: p, today: "2026-11-18")
        XCTAssertEqual(f.today, 7000)
        XCTAssertEqual(f.weekTotal, 28000)
        XCTAssertEqual(f.weekAverage, 4000)
    }

    /// A day older than the window must not be dragged into "this week", which is why the window is counted
    /// in day keys and not in list positions.
    func testADayOutsideTheWindowIsNotInTheWeek() {
        let p = points([("2026-10-01", 99999), ("2026-11-17", 100), ("2026-11-18", 200)])
        let f = MeasureFacts.read(points: p, today: "2026-11-18")
        XCTAssertEqual(f.weekTotal, 300)
        XCTAssertEqual(f.weekAverage, 150)
    }

    /// A missing day is skipped, never counted as zero: a day without a weigh-in is not a weight of nothing,
    /// and averaging it in would quietly drag every average down.
    func testMissingDaysAreSkippedRatherThanCountedAsZero() {
        let p = points([("2026-11-14", 80), ("2026-11-18", 100)])
        let f = MeasureFacts.read(points: p, today: "2026-11-18")
        XCTAssertEqual(f.weekAverage, 90)
    }

    /// Weight: what the tile means by "last weighed", including that it may be days ago.
    func testTheNewestReadingCanBeOlderThanToday() {
        let p = points([("2026-11-14", 97.6), ("2026-11-16", 97.2)])
        let f = MeasureFacts.read(points: p, today: "2026-11-18")
        XCTAssertNil(f.today, "nothing was recorded today, and the tile must be able to say so")
        XCTAssertEqual(f.lastValue, 97.2)
        XCTAssertEqual(f.lastDay, "2026-11-16")
        XCTAssertEqual(f.daysSinceLast, 2)
    }

    /// "Which way it has gone this week" for a measure nobody records daily: the newest against the newest
    /// reading at least a week older, not against whatever happens to be seven places back in the list.
    func testTheWeekChangeComparesAgainstAReadingAWeekOlder() {
        let p = points([("2026-11-01", 99.0), ("2026-11-09", 98.0), ("2026-11-16", 97.2)])
        let f = MeasureFacts.read(points: p, today: "2026-11-18")
        XCTAssertEqual(f.weekChange ?? 0, -0.8, accuracy: 0.0001)
    }

    func testNoWeekChangeWithoutAnOlderReading() {
        XCTAssertNil(MeasureFacts.read(points: points([("2026-11-16", 97.2)]), today: "2026-11-18").weekChange)
    }

    /// Calories and protein: what is left of the day's goal, and that it never goes negative.
    func testWhatIsLeftOfTheTarget() {
        let f = MeasureFacts.read(points: points([("2026-11-18", 1840)]), today: "2026-11-18", target: 2360)
        XCTAssertEqual(f.targetLeft, 520)
        let over = MeasureFacts.read(points: points([("2026-11-18", 2500)]), today: "2026-11-18", target: 2360)
        XCTAssertEqual(over.targetLeft, 0, "past the goal there is nothing left, not a negative amount left")
    }

    func testNoTargetMeansNothingLeftToSay() {
        let f = MeasureFacts.read(points: points([("2026-11-18", 1840)]), today: "2026-11-18")
        XCTAssertNil(f.target)
        XCTAssertNil(f.targetLeft)
    }

    /// The row-wide form's curve, and that an unordered series is put in order first.
    func testTheCurveIsTheLastThirtyInOrder() {
        let p = points((1...40).map { (String(format: "2026-10-%02d", $0 <= 31 ? $0 : 31), Double($0)) })
        let f = MeasureFacts.read(points: p, today: "2026-11-18")
        XCTAssertEqual(f.last30.count, 30)
        XCTAssertEqual(f.last30.last, 40)
    }

    func testAnEmptySeriesAnswersNothingRatherThanZero() {
        let f = MeasureFacts.read(points: [], today: "2026-11-18", target: 2000)
        XCTAssertNil(f.today); XCTAssertNil(f.weekAverage); XCTAssertNil(f.weekTotal)
        XCTAssertNil(f.lastValue); XCTAssertNil(f.daysSinceLast); XCTAssertNil(f.targetLeft)
        XCTAssertTrue(f.last30.isEmpty)
    }

    /// Day keys are labels, not moments: shifting one must not depend on the phone's zone or on a clock
    /// change, which is why the shift runs in UTC.
    func testDayKeysShiftAcrossMonthAndYearEnds() {
        XCTAssertEqual(MeasureFacts.dayKey("2026-01-03", minusDays: 6), "2025-12-28")
        XCTAssertEqual(MeasureFacts.days(from: "2026-02-26", to: "2026-03-02"), 4)
    }
}
