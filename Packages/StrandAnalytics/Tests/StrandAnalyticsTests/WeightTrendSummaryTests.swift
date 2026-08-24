import XCTest
@testable import StrandAnalytics

/// `WeightTrendSummary` — the numbers the weight screen shows.
///
/// The point of these tests is the difference between a RAW reading and the TREND: a summary computed
/// off raw mornings would report a kilo of water as a week's progress, which is the failure the
/// 10-day EWMA exists to prevent.
final class WeightTrendSummaryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// `daysAgo` samples, oldest first.
    private func series(_ values: [(daysAgo: Int, kg: Double)]) -> [(date: Date, value: Double)] {
        values
            .map { (date: now.addingTimeInterval(-Double($0.daysAgo) * 86_400), value: $0.kg) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Nothing to summarise

    func testEmptyHistoryHasNoSummary() {
        XCTAssertNil(WeightTrendSummary.summarize([], now: now))
    }

    /// A 0 kg sample and a pounds figure mistaken for kg are rejected by the shared plausibility
    /// bounds, not smoothed into the trend.
    func testImplausibleReadingsAreDroppedEntirely() {
        XCTAssertNil(WeightTrendSummary.summarize(series([(1, 0.0), (2, 900.0)]), now: now))
    }

    func testImplausibleReadingsDoNotShiftTheTrend() {
        let clean = WeightTrendSummary.summarize(series([(2, 82.0), (1, 82.0)]), now: now)
        let polluted = WeightTrendSummary.summarize(series([(3, 0.0), (2, 82.0), (1, 82.0)]), now: now)
        XCTAssertEqual(clean?.trendKg, polluted?.trendKg)
    }

    // MARK: - Latest vs trend

    /// The latest RAW reading is reported as measured — the screen shows what the scale said.
    func testLatestIsTheRawNewestReading() {
        let s = WeightTrendSummary.summarize(series([(2, 82.0), (0, 84.0)]), now: now)
        XCTAssertEqual(s?.latestKg, 84.0)
    }

    /// …but the TREND barely moves for it. A 6 kg spike on a 10-day half-life shifts the centre by
    /// only a few hundred grams, which is the documented behaviour of `GoalMeasure.weightTrend`.
    func testOneSpikeBarelyMovesTheTrend() {
        var days: [(daysAgo: Int, kg: Double)] = (1...30).reversed().map { (daysAgo: $0, kg: 80.0) }
        days.append((daysAgo: 0, kg: 86.0))
        let s = WeightTrendSummary.summarize(series(days), now: now)
        let trend = try? XCTUnwrap(s?.trendKg)
        XCTAssertNotNil(trend)
        XCTAssertLessThan(abs((trend ?? 0) - 80.0), 0.6, "a single 6 kg spike must not become the trend")
        XCTAssertEqual(s?.latestKg, 86.0, "the raw reading is still reported honestly")
    }

    /// A SUSTAINED change is followed in full — the opposite failure (a trend frozen at last month's
    /// weight) is the one `GoalMeasure` explicitly refuses. Convergence is exponential at the
    /// configured half-life, so after N daily readings at the new level the residual is
    /// `step × 2^(−N/halfLife)`: 30 days at 80 kg after 85 kg leaves ~0.6 kg, 60 days leaves ~0.08 kg.
    /// Asserted against that analytic value rather than a round number, so the test pins the actual
    /// smoothing rather than whatever threshold happened to pass.
    func testSustainedChangeIsFollowed() {
        var days: [(daysAgo: Int, kg: Double)] = (61...90).reversed().map { (daysAgo: $0, kg: 85.0) }
        days += (0...60).reversed().map { (daysAgo: $0, kg: 80.0) }
        let s = WeightTrendSummary.summarize(series(days), now: now)
        XCTAssertNotNil(s)

        let expectedResidual = 5.0 * pow(0.5, 61.0 / GoalMeasure.weightTrend.halfLifeDays)
        XCTAssertLessThan(abs((s?.trendKg ?? 0) - (80.0 + expectedResidual)), 0.05,
                          "the trend must converge on the new level at the configured half-life")
        XCTAssertLessThan(abs((s?.trendKg ?? 0) - 80.0), 0.2,
                          "after six half-lives the old level must be gone from the trend")
    }

    // MARK: - Reliability

    func testTrendIsUnreliableUntilEnoughReadings() {
        let thin = WeightTrendSummary.summarize(series([(2, 82.0), (1, 82.1)]), now: now)
        XCTAssertEqual(thin?.isTrendReliable, false)

        let enough = WeightTrendSummary.summarize(
            series([(4, 82.0), (3, 82.1), (2, 81.9), (1, 82.0)]), now: now)
        XCTAssertEqual(enough?.isTrendReliable, true)
    }

    func testReadingCountCountsOnlyPlausibleReadings() {
        let s = WeightTrendSummary.summarize(series([(3, 0.0), (2, 82.0), (1, 82.5)]), now: now)
        XCTAssertEqual(s?.readingCount, 2)
    }

    // MARK: - Changes over time

    /// A history that does not reach back far enough has NO 7/30-day change. Zero would claim a
    /// stability nobody measured.
    func testShortHistoryHasNoChangeFigures() {
        let s = WeightTrendSummary.summarize(series([(1, 82.0), (0, 82.0)]), now: now)
        XCTAssertNil(s?.change7dKg)
        XCTAssertNil(s?.change30dKg)
    }

    func testSevenDayChangeIsNegativeWhileLosing() {
        let days: [(daysAgo: Int, kg: Double)] = (0...40).reversed().map {
            (daysAgo: $0, kg: 80.0 + Double($0) * 0.05)   // older days heavier → losing
        }
        let s = WeightTrendSummary.summarize(series(days), now: now)
        let change = try? XCTUnwrap(s?.change7dKg)
        XCTAssertNotNil(change)
        XCTAssertLessThan(change ?? 0, 0, "losing weight must read as a negative 7-day change")
    }

    func testThirtyDayChangeSpansMoreThanTheSevenDayOne() {
        let days: [(daysAgo: Int, kg: Double)] = (0...60).reversed().map {
            (daysAgo: $0, kg: 80.0 + Double($0) * 0.05)
        }
        let s = WeightTrendSummary.summarize(series(days), now: now)
        guard let d7 = s?.change7dKg, let d30 = s?.change30dKg else {
            return XCTFail("both change figures should exist over a 60-day history")
        }
        XCTAssertLessThan(d30, d7, "a steady loss must show a bigger drop over 30 days than over 7")
    }

    // MARK: - The drawable series

    /// The line a chart plots and the number beside it must come from the SAME fold — otherwise the
    /// headline says 80.0 while the curve ends somewhere else.
    func testSmoothedSeriesEndsOnTheSummarysTrend() {
        let input = series((0...20).reversed().map { (daysAgo: $0, kg: 80.0 + Double($0) * 0.05) })
        let summary = WeightTrendSummary.summarize(input, now: now)
        let line = WeightTrendSummary.smoothedSeries(input)
        XCTAssertEqual(line.last?.value, summary?.trendKg)
    }

    /// One centre per KEPT reading, paired with that reading's own date. Filtering inside the function
    /// is what keeps dates and centres aligned — doing it at the call site would shift every point.
    func testSmoothedSeriesDropsImplausibleReadingsAndKeepsDatesAligned() {
        let input = series([(3, 82.0), (2, 0.0), (1, 81.0)])
        let line = WeightTrendSummary.smoothedSeries(input)
        XCTAssertEqual(line.count, 2, "the 0 kg sample is dropped, not smoothed")
        XCTAssertEqual(line.map(\.date), input.filter { $0.value > 1 }.map(\.date))
    }

    func testSmoothedSeriesOfNothingIsEmpty() {
        XCTAssertTrue(WeightTrendSummary.smoothedSeries([]).isEmpty)
    }

    // MARK: - Rate

    func testRateNeedsEnoughSpanAndPoints() {
        let s = WeightTrendSummary.summarize(series([(3, 82.0), (2, 81.8), (1, 81.6)]), now: now)
        XCTAssertNil(s?.ratePerWeekKg, "three readings over three days is not a rate")
    }

    func testRateIsReportedPerWeekAndSigned() {
        // ~0.1 kg/day down over 40 days → about −0.7 kg/week.
        let days: [(daysAgo: Int, kg: Double)] = (0...40).reversed().map {
            (daysAgo: $0, kg: 80.0 + Double($0) * 0.1)
        }
        let s = WeightTrendSummary.summarize(series(days), now: now)
        let rate = try? XCTUnwrap(s?.ratePerWeekKg)
        XCTAssertNotNil(rate)
        XCTAssertLessThan(rate ?? 0, 0)
        XCTAssertLessThan(abs((rate ?? 0) - (-0.7)), 0.2, "expected roughly −0.7 kg/week, got \(rate ?? 0)")
    }

    /// Input order must not matter: a caller appending an edited past weigh-in should get the same
    /// answer as one that happened to store them chronologically.
    func testInputOrderDoesNotChangeTheResult() {
        let days: [(daysAgo: Int, kg: Double)] = (0...30).reversed().map {
            (daysAgo: $0, kg: 80.0 + Double($0) * 0.05)
        }
        let ordered = WeightTrendSummary.summarize(series(days), now: now)
        let shuffled = WeightTrendSummary.summarize(series(days).shuffled(), now: now)
        XCTAssertEqual(ordered, shuffled)
    }
}
