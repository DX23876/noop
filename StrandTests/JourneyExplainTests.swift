import XCTest
@testable import Strand

/// The Journey page's definitions and its trend arithmetic (#coach-bugs).
///
/// The page's standing rule is "no invented percentages"; these tests pin its corollary — that every
/// number it DOES show is derived from stated inputs, and that a goal without those inputs gets an honest
/// "not measurable" rather than a confident-looking verdict. Pure: no view, no store, no strap.
final class JourneyExplainTests: XCTestCase {

    private func goal(kind: CoachGoal.Kind,
                      baseline: Double?,
                      target: Double?,
                      createdAt: Date,
                      targetDate: Date?) -> CoachGoal {
        CoachGoal(kind: kind, title: "Test goal", baseline: baseline, target: target,
                  targetDate: targetDate, createdAt: createdAt)
    }

    private func days(_ n: Double) -> TimeInterval { n * 24 * 3600 }

    // MARK: - Session rules: the right noun and a stated definition per kind

    func testEveryKindHasANonEmptyDefinition() {
        for kind in CoachGoal.Kind.allCases {
            let rule = JourneyExplain.sessionRule(for: kind)
            XCTAssertFalse(rule.definition.isEmpty, "\(kind) must say what counts towards it")
            XCTAssertFalse(rule.noun.isEmpty)
            XCTAssertFalse(rule.pluralNoun.isEmpty)
        }
    }

    func testSleepGoalIsCountedInNightsNotSessions() {
        let rule = JourneyExplain.sessionRule(for: .sleep)
        XCTAssertEqual(rule.noun, "night")
        XCTAssertFalse(rule.allowsManualLog, "nights come from the strap; there is nothing to tick off")
    }

    func testWeightGoalIsCountedInWeighIns() {
        XCTAssertEqual(JourneyExplain.sessionRule(for: .weight).noun, "weigh-in")
    }

    /// The custom-goal fallback: NOOP can't categorise it, so it must still offer a way to record work
    /// against it rather than leaving the counter stuck at zero forever.
    func testCustomGoalAllowsManualLogging() {
        let rule = JourneyExplain.sessionRule(for: .custom)
        XCTAssertTrue(rule.allowsManualLog)
        XCTAssertTrue(rule.countsPlanSessions)
    }

    func testStressGoalAllowsManualLogging() {
        XCTAssertTrue(JourneyExplain.sessionRule(for: .stress).allowsManualLog)
    }

    // MARK: - Count line

    func testZeroCountUsesThePluralNounOfTheKind() {
        XCTAssertTrue(JourneyExplain.countLine(for: .sleep, count: 0).contains("nights"))
        XCTAssertTrue(JourneyExplain.countLine(for: .stress, count: 0).contains("sessions"))
    }

    func testSingleCountIsNotPluralised() {
        XCTAssertTrue(JourneyExplain.countLine(for: .run, count: 1).contains("1 session"))
        XCTAssertFalse(JourneyExplain.countLine(for: .run, count: 1).contains("1 sessions"))
    }

    // MARK: - Progress explanation

    func testEveryKindExplainsItsProgressBar() {
        for kind in CoachGoal.Kind.allCases {
            XCTAssertFalse(JourneyExplain.progressExplanation(for: kind).isEmpty)
        }
    }

    // MARK: - Trend: never a verdict without the inputs to justify one

    func testUnquantifiableKindHasNoTrend() {
        let g = goal(kind: .custom, baseline: nil, target: nil,
                     createdAt: Date().addingTimeInterval(-days(30)),
                     targetDate: Date().addingTimeInterval(days(30)))
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 5).verdict, .notMeasurable)
    }

    func testMissingMeasurementHasNoTrend() {
        let g = goal(kind: .run, baseline: 5, target: 10,
                     createdAt: Date().addingTimeInterval(-days(30)),
                     targetDate: Date().addingTimeInterval(days(30)))
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: nil).verdict, .notMeasurable)
    }

    func testMissingTargetDateHasNoTrend() {
        let g = goal(kind: .run, baseline: 5, target: 10,
                     createdAt: Date().addingTimeInterval(-days(30)), targetDate: nil)
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 7).verdict, .notMeasurable)
    }

    func testEqualBaselineAndTargetHasNoTrend() {
        let g = goal(kind: .run, baseline: 10, target: 10,
                     createdAt: Date().addingTimeInterval(-days(30)),
                     targetDate: Date().addingTimeInterval(days(30)))
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 10).verdict, .notMeasurable)
    }

    /// A goal set days ago against a months-long runway can't be "behind" in any meaningful sense.
    func testTooEarlyInTheRunwayHasNoTrend() {
        let now = Date()
        let g = goal(kind: .run, baseline: 5, target: 10,
                     createdAt: now.addingTimeInterval(-days(2)),
                     targetDate: now.addingTimeInterval(days(98)))
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 5, now: now).verdict, .notMeasurable)
    }

    // MARK: - Trend verdicts

    func testHalfwayInTimeAndHalfwayInProgressIsOnTrack() {
        let now = Date()
        let g = goal(kind: .run, baseline: 5, target: 15,
                     createdAt: now.addingTimeInterval(-days(50)),
                     targetDate: now.addingTimeInterval(days(50)))
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 10, now: now).verdict, .onTrack)
    }

    func testMoreProgressThanTimeElapsedIsAhead() {
        let now = Date()
        let g = goal(kind: .run, baseline: 5, target: 15,
                     createdAt: now.addingTimeInterval(-days(20)),
                     targetDate: now.addingTimeInterval(days(80)))
        // 20% of the time gone, 80% of the distance gained.
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 13, now: now).verdict, .ahead)
    }

    func testNoMovementLateInTheRunwayIsBehind() {
        let now = Date()
        let g = goal(kind: .run, baseline: 5, target: 15,
                     createdAt: now.addingTimeInterval(-days(80)),
                     targetDate: now.addingTimeInterval(days(20)))
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 5, now: now).verdict, .behind)
    }

    /// A weight goal counts DOWNWARD; the same fraction arithmetic has to read it the same way up.
    func testDownwardGoalIsJudgedInItsOwnDirection() {
        let now = Date()
        let g = goal(kind: .weight, baseline: 85, target: 80,
                     createdAt: now.addingTimeInterval(-days(50)),
                     targetDate: now.addingTimeInterval(days(50)))
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 82.5, now: now).verdict, .onTrack)
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 85, now: now).verdict, .behind)
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 80, now: now).verdict, .ahead)
    }

    /// Moving the WRONG way is behind, not an out-of-range crash or a clamped-to-zero "on track".
    func testMovingAwayFromTheTargetIsBehind() {
        let now = Date()
        let g = goal(kind: .weight, baseline: 85, target: 80,
                     createdAt: now.addingTimeInterval(-days(50)),
                     targetDate: now.addingTimeInterval(days(50)))
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 87, now: now).verdict, .behind)
    }

    /// Past the target date the sentence and the verdict have to agree. `elapsedPct` was clamped for
    /// display while the comparison used the raw fraction, so a goal reached three weeks after its
    /// date read "100% of the way … with 100% of the time gone. That's behind the pace" — a sentence
    /// that refutes itself in its own last clause.
    func testAReachedGoalPastItsDateIsNotCalledBehind() {
        let now = Date()
        let g = goal(kind: .run, baseline: 5, target: 10,
                     createdAt: now.addingTimeInterval(-days(100)),
                     targetDate: now.addingTimeInterval(-days(21)))
        let trend = JourneyExplain.trend(goal: g, current: 10, now: now)
        XCTAssertNotEqual(trend.verdict, .behind,
                          "the target was reached; only the date is late")
        XCTAssertTrue(trend.line.contains("100"), "and the line still reports 100% of the time gone")
    }

    /// The other half: an overdue goal that genuinely did NOT move is still behind. Clamping elapsed
    /// time must not turn every expired goal into "on track".
    func testAnUnmovedGoalPastItsDateIsStillBehind() {
        let now = Date()
        let g = goal(kind: .run, baseline: 5, target: 10,
                     createdAt: now.addingTimeInterval(-days(100)),
                     targetDate: now.addingTimeInterval(-days(21)))
        XCTAssertEqual(JourneyExplain.trend(goal: g, current: 5, now: now).verdict, .behind)
    }

    func testEveryTrendCarriesANonEmptyLine() {
        let now = Date()
        let g = goal(kind: .run, baseline: 5, target: 15,
                     createdAt: now.addingTimeInterval(-days(50)),
                     targetDate: now.addingTimeInterval(days(50)))
        for current: Double? in [nil, 5, 10, 15] {
            XCTAssertFalse(JourneyExplain.trend(goal: g, current: current, now: now).line.isEmpty)
        }
    }

    func testEveryVerdictHasAReadableWord() {
        for verdict: JourneyExplain.TrendVerdict in [.ahead, .onTrack, .behind, .notMeasurable] {
            XCTAssertFalse(JourneyExplain.label(for: verdict).isEmpty,
                           "the verdict must never be carried by colour alone")
        }
    }
}
