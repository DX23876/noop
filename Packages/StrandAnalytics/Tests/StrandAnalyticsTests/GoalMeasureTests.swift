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
