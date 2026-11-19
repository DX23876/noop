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

    // MARK: - The kit round's facts (owner, 2026-11-19)

    /// The best mark follows the measure, not the arithmetic: the highest HRV and the lowest resting pulse
    /// are both "best", and a tile must not call a high resting pulse a record.
    func testTheBestMarkFollowsTheMeasuresOwnDirection() {
        let p = points([("2026-11-14", 40), ("2026-11-15", 62), ("2026-11-16", 51)])
        let up = MeasureFacts.read(points: p, today: "2026-11-18", direction: .higherIsBetter)
        XCTAssertEqual(up.best, 62)
        XCTAssertEqual(up.bestDay, "2026-11-15")
        let down = MeasureFacts.read(points: p, today: "2026-11-18", direction: .lowerIsBetter)
        XCTAssertEqual(down.best, 40)
        XCTAssertEqual(down.bestDay, "2026-11-14")
    }

    /// Weight and skin temperature claim no best at all, which is the point of asking the direction rather
    /// than taking the maximum of whatever is there.
    func testAMeasureWithNoBetterDirectionClaimsNoBest() {
        let f = MeasureFacts.read(points: points([("2026-11-17", 97.2), ("2026-11-18", 98.0)]), today: "2026-11-18")
        XCTAssertNil(f.best); XCTAssertNil(f.bestDay)
        XCTAssertEqual(MeasureFacts.direction(forKey: "weight"), .neither)
        XCTAssertEqual(MeasureFacts.direction(forKey: "skin_temp"), .neither)
        XCTAssertEqual(MeasureFacts.direction(forKey: "hrv"), .higherIsBetter)
        XCTAssertEqual(MeasureFacts.direction(forKey: "rhr"), .lowerIsBetter)
    }

    /// The best mark names a day inside the thirty the chart draws, not the best entry in the whole history:
    /// a record from last spring under a thirty-day curve is a figure the picture cannot show.
    func testTheBestMarkStaysInsideTheDrawnWindow() {
        let p = points([("2026-05-01", 99), ("2026-11-10", 61), ("2026-11-18", 55)])
        let f = MeasureFacts.read(points: p, today: "2026-11-18", direction: .higherIsBetter)
        XCTAssertEqual(f.best, 61)
        XCTAssertEqual(f.daysWithEntry, 2, "only the two days inside the window count")
    }

    /// "5 of 7 days over the goal": both numbers come from the same read, so the count and what it is out
    /// of cannot disagree.
    func testTheDaysOverTheGoalAreCountedAgainstTheDaysThatHaveOne() {
        let p = points([("2026-11-13", 12000), ("2026-11-15", 4000), ("2026-11-16", 11000),
                        ("2026-11-18", 9000)])
        let f = MeasureFacts.read(points: p, today: "2026-11-18", target: 8000)
        XCTAssertEqual(f.daysAboveTarget, 3)
        XCTAssertEqual(f.weekDaysWithEntry, 4)
        XCTAssertNil(MeasureFacts.read(points: p, today: "2026-11-18").daysAboveTarget,
                     "without a goal there is nothing to be above")
        // And the strip says the same denominator the caption does. A fixed seven read "3 of 7" under a
        // caption saying "3 of 4 days reached", on one card.
        let block = MeasureFacts.strip(key: "steps", facts: f, values: p.map(\.value))
            .first { $0.item == .daysOverGoal }
        XCTAssertEqual(block?.count, 3)
        XCTAssertEqual(block?.total, 4)
    }

    /// The blocks under a week of bars are the week's, because the list that decides the picture is the
    /// one that decides them. Protein draws its week and used to fall to the default blocks: a range read
    /// over thirty readings under seven bars, and the daily average its caption already carries.
    func testAMeasureDrawnAsAWeekTakesTheWeeksBlocks() {
        let days = (12...18).map { ("2026-11-\(String(format: "%02d", $0))", Double(100 + $0)) }
        let f = MeasureFacts.read(points: points(days), today: "2026-11-18", target: 120,
                                  direction: .higherIsBetter)
        for key in ["protein_g", "steps", "calories_in", "water_ml"] {
            XCTAssertTrue(MeasureFacts.drawsTheWeek(forKey: key), key)
            let items = MeasureFacts.strip(key: key, facts: f, values: days.map(\.1)).map(\.item)
            XCTAssertEqual(items, [.best, .daysOverGoal, .weekTotal], key)
        }
        let hrv = MeasureFacts.strip(key: "hrv", facts: f, values: days.map(\.1)).map(\.item)
        XCTAssertFalse(hrv.contains(.weekTotal), "a measure drawn as thirty days keeps its own blocks")
    }

    /// "7 of the last 10 nights above your usual" needs eleven readings before it can be said, since the
    /// usual itself is read from the ones before the newest.
    func testTheCountAgainstTheUsualWaitsUntilThereAreTenToCount() {
        let short = (1...10).map { ("2026-11-\(String(format: "%02d", $0))", Double(50)) }
        XCTAssertNil(MeasureFacts.read(points: points(short), today: "2026-11-18").aboveUsualRecently)
        // Eleven days: ten at 50, then a run above the median of the ones before it.
        var pairs = (1...6).map { ("2026-11-\(String(format: "%02d", $0))", Double(50)) }
        pairs += (7...11).map { ("2026-11-\(String(format: "%02d", $0))", Double(60)) }
        let f = MeasureFacts.read(points: points(pairs), today: "2026-11-11")
        XCTAssertEqual(f.aboveUsualRecently, 5)
    }

    /// A day total's wider form draws the WEEK, so its best mark must name a day inside that week. Under
    /// seven bars beginning on a Friday, "highest on 26 Oct" is a figure the reader cannot find — seen on
    /// screen on 2026-11-19, on the steps tile.
    func testADayTotalNamesItsBestInsideTheWeekItDraws() {
        let p = points([("2026-11-05", 13_729), ("2026-11-16", 9_000), ("2026-11-18", 11_000)])
        let f = MeasureFacts.read(points: p, today: "2026-11-18", direction: .higherIsBetter)
        XCTAssertEqual(f.best, 13_729, "the thirty-day best is still there for the measures that draw it")
        XCTAssertEqual(f.weekBest, 11_000)
        XCTAssertEqual(f.weekBestDay, "2026-11-18")
        let strip = MeasureFacts.strip(key: "steps", facts: f, values: p.map(\.value))
        XCTAssertEqual(strip.first?.item, .best)
        XCTAssertEqual(strip.first?.day, "2026-11-18", "steps draw the week, so the mark is the week's")
        let hrv = MeasureFacts.strip(key: "hrv", facts: f, values: p.map(\.value))
        XCTAssertEqual(hrv.first?.day, "2026-11-05", "HRV draws thirty days, so the mark is those thirty")
        XCTAssertTrue(MeasureFacts.drawsTheWeek(forKey: "steps"))
        XCTAssertFalse(MeasureFacts.drawsTheWeek(forKey: "hrv"))
    }

    /// Day keys are labels, not moments: shifting one must not depend on the phone's zone or on a clock
    /// change, which is why the shift runs in UTC.
    func testDayKeysShiftAcrossMonthAndYearEnds() {
        XCTAssertEqual(MeasureFacts.dayKey("2026-01-03", minusDays: 6), "2025-12-28")
        XCTAssertEqual(MeasureFacts.days(from: "2026-02-26", to: "2026-03-02"), 4)
    }
}
