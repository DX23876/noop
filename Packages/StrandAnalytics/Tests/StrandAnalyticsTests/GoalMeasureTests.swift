import XCTest
@testable import StrandAnalytics

final class GoalMeasureTests: XCTestCase {

    // MARK: - Weekly execution threshold

    /// The whole table, pinned. The bug this replaces was invisible precisely because nobody wrote the
    /// mapping down: `ceil(planned × 0.8)` reads like "80%" but demands 100% for every week of 1-4.
    func testWeeklyThresholdTable() {
        let expected = [1: 1, 2: 1, 3: 2, 4: 3, 5: 4, 6: 5, 7: 6]
        for (planned, required) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(GoalMeasure.requiredCompletions(for: planned), required,
                           "planned=\(planned)")
        }
        XCTAssertEqual(GoalMeasure.requiredCompletions(for: 0), 0)
        XCTAssertEqual(GoalMeasure.requiredCompletions(for: -3), 0)
    }

    /// Two properties that matter more than any single row: a small week may drop exactly one, and the
    /// rule is never stricter than the plain 80% it replaced (so no existing week can newly fail).
    func testThresholdIsNeverStricterThanEightyPercentAndAllowsOneMiss() {
        for planned in 1...30 {
            let required = GoalMeasure.requiredCompletions(for: planned)
            let plainEightyPercent = Int(ceil(Double(planned) * 0.8))
            XCTAssertLessThanOrEqual(required, plainEightyPercent, "planned=\(planned)")
            XCTAssertGreaterThanOrEqual(required, 1, "planned=\(planned)")
            if planned >= 2 {
                XCTAssertLessThanOrEqual(required, planned - 1,
                                         "a week of \(planned) must tolerate one miss")
            }
        }
    }

    /// Monotonic: planning one more session can never lower the bar.
    func testThresholdIsMonotonic() {
        var previous = 0
        for planned in 1...30 {
            let required = GoalMeasure.requiredCompletions(for: planned)
            XCTAssertGreaterThanOrEqual(required, previous, "planned=\(planned)")
            previous = required
        }
    }

    // MARK: - Smoothed trend

    /// A flat series smooths to its own level: no drift, no lag artefact.
    func testSmoothedTrendOfAConstantSeriesIsThatConstant() {
        let smoothed = GoalMeasure.smoothedTrend(Array(repeating: 80.0, count: 40),
                                                 cfg: GoalMeasure.weightTrend)
        XCTAssertNotNil(smoothed)
        XCTAssertEqual(smoothed!.value, 80.0, accuracy: 0.05)
        XCTAssertTrue(smoothed!.isReliable)
    }

    /// The point of the change: one absurd morning must not move the number the goal is judged on.
    /// A raw "latest reading" would have reported 86 kg here.
    func testSingleOutlierBarelyMovesTheTrend() {
        var series = Array(repeating: 80.0, count: 40)
        let clean = GoalMeasure.smoothedTrend(series, cfg: GoalMeasure.weightTrend)!.value
        series.append(86.0)
        let spiked = GoalMeasure.smoothedTrend(series, cfg: GoalMeasure.weightTrend)!.value
        XCTAssertLessThan(abs(spiked - clean), 0.6,
                          "a 6 kg one-day spike moved the trend by \(spiked - clean) kg")
    }

    /// A real, sustained change must still come through — smoothing that never moves is just a lie
    /// with less noise.
    func testSustainedChangeIsFollowed() {
        let series = Array(repeating: 80.0, count: 30) + Array(repeating: 77.0, count: 30)
        let smoothed = GoalMeasure.smoothedTrend(series, cfg: GoalMeasure.weightTrend)!
        XCTAssertEqual(smoothed.value, 77.0, accuracy: 0.5)
    }

    func testEmptySeriesHasNoTrend() {
        XCTAssertNil(GoalMeasure.smoothedTrend([], cfg: GoalMeasure.weightTrend))
    }

    /// Cold start is reported, not hidden: the caller shows the number but must not judge on it.
    func testShortSeriesIsNotYetReliable() {
        let smoothed = GoalMeasure.smoothedTrend([80.0], cfg: GoalMeasure.weightTrend)
        XCTAssertNotNil(smoothed)
        XCTAssertFalse(smoothed!.isReliable)
    }

    // MARK: - Smoothed series (the rate-fit input)

    /// `GoalMilestones.observedRatePerDay` fits a slope through this, and a caller pairs it with dates
    /// — so it must return one centre per KEPT value, and the last one must agree with the level read
    /// off the same series. A disagreement there would mean the rate and the level describe different
    /// smoothings of the same weigh-ins.
    func testSmoothedSeriesMatchesTheTrendItEndsOn() {
        let series = Array(repeating: 80.0, count: 20) + Array(repeating: 76.0, count: 20)
        let centres = GoalMeasure.smoothedSeries(series, cfg: GoalMeasure.weightTrend)
        XCTAssertEqual(centres.count, series.count)
        XCTAssertEqual(centres.last!,
                       GoalMeasure.smoothedTrend(series, cfg: GoalMeasure.weightTrend)!.value,
                       accuracy: 1e-9)
    }

    /// The alignment contract `isPlausible` exists for: implausible readings are dropped, so a caller
    /// zipping dates against the result has to drop exactly the same ones or every sample shifts day.
    func testSmoothedSeriesDropsImplausibleValuesAndIsPlausibleAgrees() {
        let series = [80.0, 0.0, 79.0, 900.0, 78.0]
        let centres = GoalMeasure.smoothedSeries(series, cfg: GoalMeasure.weightTrend)
        let kept = series.filter { GoalMeasure.isPlausible($0, cfg: GoalMeasure.weightTrend) }
        XCTAssertEqual(kept, [80.0, 79.0, 78.0])
        XCTAssertEqual(centres.count, kept.count,
                       "one centre per kept value, or dates and values stop lining up")
    }

    func testSmoothedSeriesOfNothingIsEmpty() {
        XCTAssertTrue(GoalMeasure.smoothedSeries([], cfg: GoalMeasure.weightTrend).isEmpty)
    }

    // MARK: - Score trend (recovery / stress)

    /// The reason recovery and stress moved off a plain mean: a two-day window used to produce a fully
    /// judgeable number, and "at risk" could be raised off one rough night.
    func testThinScoreWindowIsNotYetReliable() {
        let smoothed = GoalMeasure.smoothedTrend([44.0, 41.0], cfg: GoalMeasure.scoreTrend)
        XCTAssertNotNil(smoothed)
        XCTAssertFalse(smoothed!.isReliable, "two readings cannot carry a verdict")
    }

    /// A 0-100 score still has to be followed when it genuinely moves, and its bounds must not reject
    /// legitimate values at either end of the scale.
    ///
    /// 40 samples past the step, not 20: with a 7-day half-life the remaining gap is
    /// `30 × 0.5^(n/7)`, which is still ~4 points at n=20 and ~0.6 at n=40. That lag is the config
    /// working as specified, so the test asserts against converged input rather than pinning a number
    /// that only holds for one window length.
    func testScoreTrendFollowsASustainedMoveAndAcceptsTheWholeScale() {
        let series = Array(repeating: 40.0, count: 20) + Array(repeating: 70.0, count: 40)
        XCTAssertEqual(GoalMeasure.smoothedTrend(series, cfg: GoalMeasure.scoreTrend)!.value,
                       70.0, accuracy: 1.0)
        XCTAssertTrue(GoalMeasure.isPlausible(0, cfg: GoalMeasure.scoreTrend))
        XCTAssertTrue(GoalMeasure.isPlausible(100, cfg: GoalMeasure.scoreTrend))
        XCTAssertFalse(GoalMeasure.isPlausible(101, cfg: GoalMeasure.scoreTrend))
    }

    // MARK: - Aggregates

    func testEmptyInputsAreNilNotZero() {
        XCTAssertNil(GoalMeasure.mean([]))
        XCTAssertNil(GoalMeasure.maximum([]))
        XCTAssertNil(GoalMeasure.perWeek(count: 3, overDays: 0))
    }

    func testPerWeekRate() {
        XCTAssertEqual(GoalMeasure.perWeek(count: 12, overDays: 28)!, 3.0, accuracy: 0.0001)
        XCTAssertEqual(GoalMeasure.perWeek(count: 0, overDays: 28)!, 0.0, accuracy: 0.0001)
    }

    /// No strength sessions in the window is a real answer (0 min/week), not "unknown" — the goal is
    /// measurable, it is just not being served.
    func testStrengthMinutesPerWeek() {
        let twoSessions = [45.0 * 60, 30.0 * 60]
        XCTAssertEqual(GoalMeasure.minutesPerWeek(durationsS: twoSessions, overDays: 7)!,
                       75.0, accuracy: 0.0001)
        XCTAssertEqual(GoalMeasure.minutesPerWeek(durationsS: twoSessions, overDays: 28)!,
                       18.75, accuracy: 0.0001)
        XCTAssertEqual(GoalMeasure.minutesPerWeek(durationsS: [], overDays: 28)!, 0.0, accuracy: 0.0001)
    }
}
