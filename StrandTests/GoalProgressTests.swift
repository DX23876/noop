import XCTest
@testable import Strand

/// `GoalProgress` — the one shared reading behind the Journey page, the Today goal card and the iOS
/// goal widget.
///
/// The rule under test is the honesty rule, not the arithmetic: a fraction may exist ONLY when a real
/// measurement and both ends of the range are present. Every "no fraction" case below is therefore a
/// requirement, not an edge case — a ring that fills on a goal NOOP cannot measure is the exact bug
/// this type was extracted to make impossible on three surfaces at once.
final class GoalProgressTests: XCTestCase {

    private let evidence = GoalFeasibility.Evidence(vo2max: 44,
                                                    longestRecentRunKm: 12,
                                                    sessionsPerWeek: 3,
                                                    meanSleepHours: 7.0)

    // MARK: - Measured kinds

    func testRunFractionFromBaselineAndTarget() {
        let goal = CoachGoal(kind: .run, title: "Half", baseline: 10, target: 21.1)
        let r = GoalProgress.reading(goal: goal, evidence: evidence, latestWeightKg: nil)
        XCTAssertEqual(r.current, 12)
        XCTAssertEqual(try XCTUnwrap(r.fraction), (12 - 10) / (21.1 - 10), accuracy: 0.0001)
        XCTAssertTrue(r.isMeasured)
    }

    func testWeightGoalCountsDownwards() {
        let goal = CoachGoal(kind: .weight, title: "Cut", baseline: 90, target: 80)
        let r = GoalProgress.reading(goal: goal, evidence: evidence, latestWeightKg: 85)
        XCTAssertEqual(try XCTUnwrap(r.fraction), 0.5, accuracy: 0.0001)
    }

    func testSleepUsesMeanNightlyHours() {
        let goal = CoachGoal(kind: .sleep, title: "Sleep 8h", baseline: 6, target: 8)
        let r = GoalProgress.reading(goal: goal, evidence: evidence, latestWeightKg: nil)
        XCTAssertEqual(try XCTUnwrap(r.fraction), 0.5, accuracy: 0.0001)
    }

    /// Consistency is a "reach this rate" goal: the fraction is sessions/target, with no baseline in
    /// the arithmetic at all.
    func testConsistencyIsRateOverTargetNotBaselineToTarget() {
        let goal = CoachGoal(kind: .consistency, title: "3x a week", baseline: 99, target: 4)
        let r = GoalProgress.reading(goal: goal, evidence: evidence, latestWeightKg: nil)
        XCTAssertEqual(try XCTUnwrap(r.fraction), 0.75, accuracy: 0.0001)
    }

    // MARK: - Clamping

    func testFractionClampsToZeroAndOne() {
        let overshoot = CoachGoal(kind: .run, title: "Done", baseline: 5, target: 10)
        XCTAssertEqual(try XCTUnwrap(GoalProgress.reading(goal: overshoot, evidence: evidence,
                                                          latestWeightKg: nil).fraction), 1.0)

        let backwards = CoachGoal(kind: .weight, title: "Gain", baseline: 80, target: 90)
        // Current 75 kg is on the far side of the baseline — behind the start, not negative progress.
        XCTAssertEqual(try XCTUnwrap(GoalProgress.reading(goal: backwards, evidence: evidence,
                                                          latestWeightKg: 75).fraction), 0.0)
    }

    // MARK: - No invented percentages

    func testUnmeasurableKindsHaveNoFractionAndNoLine() {
        for kind in [CoachGoal.Kind.strength, .stress, .recovery, .custom] {
            let goal = CoachGoal(kind: kind, title: "Something", baseline: 1, target: 10)
            let r = GoalProgress.reading(goal: goal, evidence: evidence, latestWeightKg: 80)
            XCTAssertNil(r.fraction, "\(kind) must not produce a fraction")
            XCTAssertNil(r.line, "\(kind) must not produce a progress line")
            XCTAssertNil(r.current)
            XCTAssertFalse(r.isMeasured)
        }
    }

    func testMeasurementWithoutBaselineGivesALineButNoFraction() {
        let goal = CoachGoal(kind: .weight, title: "Weight", baseline: nil, target: 80)
        let r = GoalProgress.reading(goal: goal, evidence: evidence, latestWeightKg: 85)
        XCTAssertNil(r.fraction)
        XCTAssertEqual(r.current, 85)
        XCTAssertTrue(try XCTUnwrap(r.line).contains("85"))
    }

    func testEqualBaselineAndTargetGivesNoFraction() {
        let goal = CoachGoal(kind: .weight, title: "Hold", baseline: 80, target: 80)
        XCTAssertNil(GoalProgress.reading(goal: goal, evidence: evidence, latestWeightKg: 80).fraction)
    }

    func testConsistencyWithoutATargetGivesNothingToShow() {
        let goal = CoachGoal(kind: .consistency, title: "More often", baseline: 1, target: nil)
        let r = GoalProgress.reading(goal: goal, evidence: evidence, latestWeightKg: nil)
        XCTAssertNil(r.fraction)
        XCTAssertNil(r.line)
        XCTAssertEqual(r.current, 3)
    }

    func testMissingEvidenceGivesNothingToShow() {
        let goal = CoachGoal(kind: .run, title: "Half", baseline: 10, target: 21.1)
        let r = GoalProgress.reading(goal: goal, evidence: GoalFeasibility.Evidence(), latestWeightKg: nil)
        XCTAssertNil(r.fraction)
        XCTAssertNil(r.line)
        XCTAssertNil(r.current)
    }

    // MARK: - Runway

    func testRunwayWeeksCountDownAndGoNegativeAfterTheDate() {
        let now = Date()
        let future = CoachGoal(kind: .custom, title: "Later",
                               targetDate: now.addingTimeInterval(28 * 24 * 3600))
        XCTAssertEqual(try XCTUnwrap(GoalProgress.reading(goal: future, evidence: evidence,
                                                          latestWeightKg: nil, now: now).runwayWeeks),
                       4, accuracy: 0.01)

        let past = CoachGoal(kind: .custom, title: "Passed",
                             targetDate: now.addingTimeInterval(-7 * 24 * 3600))
        XCTAssertLessThan(try XCTUnwrap(GoalProgress.reading(goal: past, evidence: evidence,
                                                             latestWeightKg: nil, now: now).runwayWeeks), 0)
    }

    func testNoTargetDateMeansNoRunway() {
        let goal = CoachGoal(kind: .custom, title: "Open ended")
        XCTAssertNil(GoalProgress.reading(goal: goal, evidence: evidence, latestWeightKg: nil).runwayWeeks)
    }
}
