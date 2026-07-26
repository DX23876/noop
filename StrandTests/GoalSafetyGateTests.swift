import XCTest
@testable import Strand

/// The safety gate is the one piece of coach logic where being wrong has real-world consequences, so
/// it is a pure function with a table of cases rather than a prompt instruction.
///
/// The two properties that matter most:
///   1. The rate is judged RELATIVE to body weight, so a heavier person is not flagged for a rate that
///      is proportionally identical to a lighter person's unflagged one.
///   2. It WARNS, it never blocks — a flagged goal is still a valid goal, it just asks for a reason.
@MainActor
final class GoalSafetyGateTests: XCTestCase {

    private func weightGoal(fromKg: Double, toKg: Double, weeks: Double) -> CoachGoal {
        CoachGoal(kind: .weight, title: "Weight",
                  baseline: fromKg, target: toKg,
                  targetDate: Date().addingTimeInterval(weeks * 7 * 24 * 3600))
    }

    // MARK: - The motivating case

    /// 20 kg in 8 weeks at 80 kg = 2.5 kg/week = 3.1% of body weight per week — far past the line.
    func testTwentyKgInTwoMonthsAtEightyKgIsVeryAggressive() {
        let goal = weightGoal(fromKg: 80, toKg: 60, weeks: 8)
        let a = GoalSafetyGate.assess(goal: goal, bodyWeightKg: 80)
        XCTAssertEqual(a.verdict, .veryAggressive)
        XCTAssertTrue(a.requiresReason, "a very aggressive rate must ask the user to justify it")
        XCTAssertNotNil(a.warning)
    }

    /// The heart of the relative-rate design: the SAME absolute 2.5 kg/week is a much smaller share of
    /// 180 kg, so it must NOT be judged as harshly as it is at 80 kg. This is what stops the gate being
    /// unfair to people starting from a high body weight.
    func testSameAbsoluteRateIsJudgedMoreMildlyAtHigherBodyWeight() {
        let atEighty = GoalSafetyGate.assess(goal: weightGoal(fromKg: 80, toKg: 60, weeks: 8),
                                             bodyWeightKg: 80)
        let atOneEighty = GoalSafetyGate.assess(goal: weightGoal(fromKg: 180, toKg: 160, weeks: 8),
                                                bodyWeightKg: 180)
        XCTAssertEqual(atEighty.verdict, .veryAggressive)
        XCTAssertEqual(atOneEighty.verdict, .aggressive,
                       "2.5 kg/week is 3.1% of 80 kg but only 1.4% of 180 kg — the same absolute rate "
                       + "must not carry the same verdict")
    }

    /// A conservative rate passes silently at any body weight.
    func testConservativeRateIsOk() {
        // 0.5 kg/week at 80 kg = 0.6% — under the 0.75% line.
        let a = GoalSafetyGate.assess(goal: weightGoal(fromKg: 80, toKg: 76, weeks: 8), bodyWeightKg: 80)
        XCTAssertEqual(a.verdict, .ok)
        XCTAssertNil(a.warning)
        XCTAssertFalse(a.requiresReason)
    }

    /// Gaining is judged on the same relative scale as losing — a bodybuilder's aggressive bulk gets the
    /// same "this is fast, tell me why" treatment rather than a different rulebook.
    func testAggressiveWeightGainIsAlsoFlagged() {
        let a = GoalSafetyGate.assess(goal: weightGoal(fromKg: 80, toKg: 95, weeks: 8), bodyWeightKg: 80)
        XCTAssertEqual(a.verdict, .veryAggressive)
        XCTAssertNotNil(a.ratePerWeek)
        XCTAssertGreaterThan(a.ratePerWeek ?? 0, 0, "a gain must read as a positive rate")
    }

    /// Without a body weight we cannot normalise, and an absolute threshold would be exactly the
    /// unfair rule this design avoids. Report the rate, judge nothing.
    func testNoBodyWeightMeansNoVerdict() {
        let a = GoalSafetyGate.assess(goal: weightGoal(fromKg: 80, toKg: 60, weeks: 8), bodyWeightKg: 0)
        XCTAssertEqual(a.verdict, .notApplicable)
        XCTAssertNotNil(a.ratePerWeek, "we still tell them the rate, we just don't grade it")
    }

    // MARK: - Nothing to judge

    func testUnquantifiedGoalIsNotApplicable() {
        let goal = CoachGoal(kind: .custom, title: "Feel better",
                             targetDate: Date().addingTimeInterval(60 * 24 * 3600))
        XCTAssertEqual(GoalSafetyGate.assess(goal: goal, bodyWeightKg: 80).verdict, .notApplicable)
    }

    func testGoalWithoutTargetDateIsNotApplicable() {
        let goal = CoachGoal(kind: .weight, title: "Weight", baseline: 80, target: 60, targetDate: nil)
        XCTAssertEqual(GoalSafetyGate.assess(goal: goal, bodyWeightKg: 80).verdict, .notApplicable)
    }

    func testPastTargetDateIsNotApplicable() {
        let goal = CoachGoal(kind: .weight, title: "Weight", baseline: 80, target: 60,
                             targetDate: Date().addingTimeInterval(-7 * 24 * 3600))
        XCTAssertEqual(GoalSafetyGate.assess(goal: goal, bodyWeightKg: 80).verdict, .notApplicable)
    }

    // MARK: - Running volume

    /// A steep weekly ramp is where running injuries come from, so it earns the same warn-and-ask
    /// treatment as an aggressive weight rate.
    func testSteepRunningRampIsVeryAggressive() {
        // 10 km → 40 km in 4 weeks = +7.5 km/week on a 10 km base = +75%/week.
        let goal = CoachGoal(kind: .run, title: "Long run", baseline: 10, target: 40,
                             targetDate: Date().addingTimeInterval(4 * 7 * 24 * 3600))
        XCTAssertEqual(GoalSafetyGate.assess(goal: goal, bodyWeightKg: 80).verdict, .veryAggressive)
    }

    func testGentleRunningRampIsOk() {
        // 30 km → 36 km in 8 weeks = +0.75 km/week on a 30 km base = +2.5%/week.
        let goal = CoachGoal(kind: .run, title: "Long run", baseline: 30, target: 36,
                             targetDate: Date().addingTimeInterval(8 * 7 * 24 * 3600))
        XCTAssertEqual(GoalSafetyGate.assess(goal: goal, bodyWeightKg: 80).verdict, .ok)
    }

    /// Scaling back carries no progression risk, however fast.
    func testReducingRunningVolumeIsNeverFlagged() {
        let goal = CoachGoal(kind: .run, title: "Back off", baseline: 60, target: 20,
                             targetDate: Date().addingTimeInterval(2 * 7 * 24 * 3600))
        XCTAssertEqual(GoalSafetyGate.assess(goal: goal, bodyWeightKg: 80).verdict, .ok)
    }
}
