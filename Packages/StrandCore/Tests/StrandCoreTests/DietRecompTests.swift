import XCTest
@testable import StrandCore

/// Recomposition and the training-day shift (owner, 2026-11-10).
final class DietRecompTests: XCTestCase {
    private let person = DietPerson(weightKg: 85, heightCm: 182, age: 38, male: true)

    private func recomp(_ mode: DietPlan.Mode = .simple, deficit: Double? = nil, weekdays: [Int]? = [2, 4, 6],
                        shift: Double? = nil) -> DietPlan {
        var p = DietPlan(goal: .recomp, mode: mode, form: .balanced, strength: true, startDay: "2026-11-02",
                         startWeightKg: 85)
        p.recompDeficitPercent = deficit
        p.trainingWeekdays = weekdays
        p.dayShift = shift
        return p
    }

    func testRecompositionRunsAFewPercentUnderTheBurn() {
        let simple = DietTargets.resolve(recomp(), person: person, burnKcal: 2_600)
        XCTAssertEqual(simple.goal, .recomp)
        XCTAssertEqual(simple.averageKcal, 2_600 * 0.95, accuracy: 0.5)
        XCTAssertEqual(simple.paceKgPerWeek, 0)
        let deeper = DietTargets.resolve(recomp(.advanced, deficit: 12), person: person, burnKcal: 2_600)
        XCTAssertEqual(deeper.averageKcal, 2_600 * 0.88, accuracy: 0.5)
        let capped = DietTargets.resolve(recomp(.advanced, deficit: 40), person: person, burnKcal: 2_600)
        XCTAssertEqual(capped.averageKcal, 2_600 * 0.85, accuracy: 0.5, "the deficit stops at 15 %")
    }

    func testProteinFollowsLeanMassWhenBodyFatIsKnown() {
        let unknown = DietTargets.resolve(recomp(), person: person, burnKcal: 2_600)
        XCTAssertEqual(unknown.proteinG, 85 * 2.0, accuracy: 0.01)
        var lean = person; lean.bodyFatPercent = 20
        let known = DietTargets.resolve(recomp(), person: lean, burnKcal: 2_600)
        // 68 kg lean mass; at 5 % deficit 2.3 + 0.8 * 5/15 g per kg.
        XCTAssertEqual(known.proteinG, 68 * (2.3 + 0.8 / 3), accuracy: 0.01)
        var odd = person; odd.bodyFatPercent = 80
        XCTAssertEqual(DietTargets.resolve(recomp(), person: odd, burnKcal: 2_600).proteinG, 85 * 2.0, accuracy: 0.01,
                       "an implausible body fat value is ignored")
    }

    func testTheSafetyLinesHoldRecompositionBack() {
        let young = DietTargets.resolve(recomp(), person: DietPerson(weightKg: 70, heightCm: 178, age: 16, male: true), burnKcal: 2_600)
        XCTAssertEqual(young.goal, .maintain)
        var pregnant = recomp(); pregnant.pregnantOrNursing = true
        XCTAssertEqual(DietTargets.resolve(pregnant, person: person, burnKcal: 2_600).goal, .maintain)
    }

    func testTheShiftKeepsTheWeeksAverage() {
        let p = recomp()   // Monday, Wednesday, Friday; 10 %
        let r = DietTargets.resolve(p, person: person, burnKcal: 2_600)
        let week = (0..<7).map { offset -> String in
            let date = WeightSeries.date(forDay: "2026-11-09")!.addingTimeInterval(Double(offset) * 86_400)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: date)
        }
        let kcal = week.map { DietTargets.kcal(on: $0, plan: p, result: r) }
        XCTAssertEqual(kcal.reduce(0, +) / 7, r.eatingDayKcal, accuracy: 0.5)
        XCTAssertEqual(kcal[0], r.eatingDayKcal * 1.1, accuracy: 0.5, "Monday trains")
        XCTAssertEqual(kcal[1], r.eatingDayKcal - r.eatingDayKcal * 0.1 * 3 / 4, accuracy: 0.5, "Tuesday rests")
        let split = try! XCTUnwrap(DietTargets.trainingAndRestKcal(plan: p, result: r, day: week[0]))
        XCTAssertEqual(split.training, kcal[0], accuracy: 1e-9, "the plan page's split is the day's own figure")
        XCTAssertEqual(split.rest, kcal[1], accuracy: 1e-9)
        let mondayMacros = FoodTargets.macros(plan: p, result: r, day: week[0])
        let tuesdayMacros = FoodTargets.macros(plan: p, result: r, day: week[1])
        XCTAssertEqual(mondayMacros.proteinG, tuesdayMacros.proteinG, accuracy: 1e-9)
        XCTAssertEqual(mondayMacros.fatG, tuesdayMacros.fatG, accuracy: 1e-9)
        XCTAssertGreaterThan(mondayMacros.carbsG, tuesdayMacros.carbsG)
    }

    func testALoggedExtraDayCountsAndCancelsTheActiveBonus() {
        var p = recomp(); p.activeDays = true
        let r = DietTargets.resolve(p, person: person, burnKcal: 2_600)
        let tuesday = "2026-11-10"
        XCTAssertTrue(DietTargets.isTrainingDay(tuesday, plan: p, training: .init(logged: [tuesday])))
        XCTAssertEqual(DietTargets.kcal(on: tuesday, plan: p, result: r, training: .init(logged: [tuesday])), r.eatingDayKcal * 1.1, accuracy: 0.5)
        XCTAssertEqual(DietActiveDay.bonusKcal(plan: p, day: tuesday, burnedKcal: 3_400, usualStrapKcal: 2_600,
                                               elapsedFraction: 1, training: .init(logged: [tuesday])), 0)
        XCTAssertGreaterThan(DietActiveDay.bonusKcal(plan: p, day: tuesday, burnedKcal: 3_400, usualStrapKcal: 2_600,
                                                     elapsedFraction: 1), 0, "a rest day keeps its bonus")
    }

    func testShiftOnlyInAdvancedForOtherGoalsAndNeverWithFasting() {
        var lose = DietPlan(goal: .lose, startDay: "2026-11-02", startWeightKg: 85)
        lose.trainingWeekdays = [2]; lose.dayShift = 0.15
        XCTAssertEqual(lose.effectiveDayShift, 0.10, "the program's default in the simple mode")
        lose.mode = .advanced
        XCTAssertEqual(lose.effectiveDayShift, 0.15)
        lose.form = .fasting52
        XCTAssertEqual(lose.effectiveDayShift, 0)
    }

    func testTheWeeklyCheckHoldsTheWeightInItsBand() {
        let p = recomp()
        let r = DietTargets.resolve(p, person: person, burnKcal: 2_600)
        func weights(_ perWeek: Double) -> [(day: String, kg: Double)] {
            (0..<21).map { i in
                let date = WeightSeries.date(forDay: "2026-11-30")!.addingTimeInterval(Double(i - 20) * 86_400)
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
                return (f.string(from: date), 85 + perWeek * Double(i) / 7)
            }
        }
        let steady = DietAdjust.weekly(plan: p, result: r, weighIns: weights(0.1), loggedDays: 6, today: "2026-11-30")
        XCTAssertEqual(steady.hold, .onPlan)
        let falling = DietAdjust.weekly(plan: p, result: r, weighIns: weights(-0.5), loggedDays: 6, today: "2026-11-30")
        XCTAssertEqual(falling.changeKcal, DietAdjust.recompStepKcal)
        let rising = DietAdjust.weekly(plan: p, result: r, weighIns: weights(0.5), loggedDays: 6, today: "2026-11-30")
        XCTAssertEqual(rising.changeKcal, -DietAdjust.recompStepKcal)
    }

    func testProgressReadsWeightFatAndStrength() {
        let p = recomp()
        let weighIns = (0..<10).map { (day: "2026-11-\(String(format: "%02d", 10 + $0))", kg: 85.2) }
        guard case .recomp(let r) = DietProgress.resolve(plan: p, goalWeightKg: nil, weighIns: weighIns,
                                                         bodyFat: [("2026-11-03", 20), ("2026-11-19", 19.2)],
                                                         strengthChangePercent: 4)
        else { return XCTFail("expected recomposition") }
        XCTAssertTrue(r.weightSteady)
        XCTAssertEqual(try XCTUnwrap(r.bodyFatChange), -0.8, accuracy: 1e-9)
        XCTAssertNil(r.waistChangeCm)
        XCTAssertTrue(r.working)
        guard case .recomp(let tape) = DietProgress.resolve(plan: p, goalWeightKg: nil, weighIns: weighIns,
                                                            waist: [("2026-10-20", 95), ("2026-11-04", 94), ("2026-11-19", 92.5)],
                                                            strengthChangePercent: -2)
        else { return XCTFail("expected recomposition") }
        XCTAssertEqual(try XCTUnwrap(tape.waistChangeCm), -1.5, accuracy: 1e-9, "only readings since the start")
        XCTAssertFalse(tape.working, "strength going down")
    }

    func testOlderPlansStillDecode() throws {
        let old = #"{"goal":"lose","mode":"simple","pacePercent":0.5,"form":"balanced","strength":false,"steering":"coached","keep":[],"startDay":"2026-11-01","startWeightKg":90,"adjustmentKcal":0,"hideNumbers":false,"pregnantOrNursing":false}"#
        let plan = try XCTUnwrap(DietPlan.decode(old))
        XCTAssertNil(plan.trainingWeekdays)
        let r = DietTargets.resolve(plan, person: DietPerson(weightKg: 90, heightCm: 180, age: 40, male: true), burnKcal: 2_600)
        XCTAssertEqual(DietTargets.shiftKcal(on: "2026-11-10", plan: plan, result: r), 0, "no training days, nothing moves")
    }
}

/// Each goal as a program, and training days from the training planner (owner, 2026-11-10).
final class DietProgramTests: XCTestCase {
    private let person = DietPerson(weightKg: 90, heightCm: 180, age: 40, male: true)

    func testProgramDefaultsPerGoal() {
        XCTAssertEqual(DietPlan(goal: .lose, startDay: "2026-11-02", startWeightKg: 90).effectiveDayShift, 0.10)
        XCTAssertEqual(DietPlan(goal: .gain, startDay: "2026-11-02", startWeightKg: 90).effectiveDayShift, 0.10)
        XCTAssertEqual(DietPlan(goal: .maintain, startDay: "2026-11-02", startWeightKg: 90).effectiveDayShift, 0)
        XCTAssertEqual(DietProgram.dietBreakEveryWeeks(DietPlan(goal: .lose, startDay: "2026-11-02", startWeightKg: 90)), 7)
        XCTAssertNil(DietProgram.dietBreakEveryWeeks(DietPlan(goal: .gain, startDay: "2026-11-02", startWeightKg: 90)))
        var advanced = DietPlan(goal: .lose, mode: .advanced, startDay: "2026-11-02", startWeightKg: 90)
        XCTAssertNil(DietProgram.dietBreakEveryWeeks(advanced), "advanced keeps the wearer's own choice")
        advanced.dietBreakEveryWeeks = 5
        XCTAssertEqual(DietProgram.dietBreakEveryWeeks(advanced), 5)
    }

    func testTheBreakWeekEatsTheBurn() {
        let plan = DietPlan(goal: .lose, startDay: "2026-11-02", startWeightKg: 90)   // a Monday
        XCTAssertEqual(DietProgram.phase(on: "2026-11-02", plan: plan, goalReachedDay: nil), .main)
        // Week 8 (days 49 to 55) is the break after seven weeks.
        XCTAssertEqual(DietProgram.phase(on: "2026-12-21", plan: plan, goalReachedDay: nil), .dietBreak)
        XCTAssertEqual(DietProgram.phase(on: "2026-12-28", plan: plan, goalReachedDay: nil), .main)
        let main = DietTargets.resolve(plan, person: person, burnKcal: 2_600)
        let rest = DietTargets.resolve(plan, person: person, burnKcal: 2_600, phase: .dietBreak)
        XCTAssertLessThan(main.averageKcal, 2_600)
        XCTAssertEqual(rest.averageKcal, 2_600, accuracy: 0.5)
        var taken = plan; taken.breakFromDay = "2026-11-20"
        XCTAssertEqual(DietProgram.phase(on: "2026-11-23", plan: taken, goalReachedDay: nil), .dietBreak)
    }

    func testReachingTheGoalStepsDownToHolding() {
        let plan = DietPlan(goal: .gain, goalWeightKg: 92, startDay: "2026-10-01", startWeightKg: 90)
        let weights = (0..<40).map { i -> (day: String, kg: Double) in
            let date = WeightSeries.date(forDay: "2026-10-01")!.addingTimeInterval(Double(i) * 86_400)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            return (f.string(from: date), 90 + Double(i) * 0.1)
        }
        let reached = DietProgram.goalReachedDay(plan: plan, goalWeightKg: 92, weighIns: weights)
        XCTAssertNotNil(reached)
        XCTAssertGreaterThanOrEqual(reached!, "2026-10-21", "the trend lags the raw readings")
        XCTAssertEqual(DietProgram.phase(on: reached!, plan: plan, goalReachedDay: reached), .transition)
        XCTAssertEqual(DietProgram.phase(on: "2026-12-01", plan: plan, goalReachedDay: reached), .holding)
        let half = DietTargets.resolve(plan, person: person, burnKcal: 2_600, phase: .transition)
        let full = DietTargets.resolve(plan, person: person, burnKcal: 2_600)
        XCTAssertEqual(half.averageKcal - 2_600, (full.averageKcal - 2_600) / 2, accuracy: 0.5)
    }

    func testTrainingPlannerDaysLeadAndSetTheWeek() {
        var plan = DietPlan(goal: .lose, startDay: "2026-11-02", startWeightKg: 90)
        plan.trainingWeekdays = [2, 4, 6]   // the chips: Monday, Wednesday, Friday
        let r = DietTargets.resolve(plan, person: person, burnKcal: 2_600)
        // The training planner has Tuesday, Thursday, Saturday and Sunday this week.
        let training = DietTrainingDays(planned: ["2026-11-10", "2026-11-12", "2026-11-14", "2026-11-15"])
        XCTAssertTrue(DietTargets.isTrainingDay("2026-11-10", plan: plan, training: training))
        XCTAssertFalse(DietTargets.isTrainingDay("2026-11-09", plan: plan, training: training), "the chips step back")
        XCTAssertEqual(DietTargets.weekTrainingCount("2026-11-09", plan: plan, training: training), 4)
        let week = ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15"]
        let sum = week.map { DietTargets.kcal(on: $0, plan: plan, result: r, training: training) }.reduce(0, +)
        XCTAssertEqual(sum / 7, r.eatingDayKcal, accuracy: 0.5, "four training days still keep the week")
        // A week the planner leaves empty falls back to the chips.
        XCTAssertTrue(DietTargets.isTrainingDay("2026-11-16", plan: plan, training: training))
    }

    func testHoldingKeepsItsBandAndBreaksHoldTheCheck() {
        let plan = DietPlan(goal: .maintain, startDay: "2026-11-02", startWeightKg: 80)
        let r = DietTargets.resolve(plan, person: DietPerson(weightKg: 80, heightCm: 180, age: 40, male: true), burnKcal: 2_500)
        func weights(_ perWeek: Double) -> [(day: String, kg: Double)] {
            (0..<21).map { i in
                let date = WeightSeries.date(forDay: "2026-11-30")!.addingTimeInterval(Double(i - 20) * 86_400)
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
                return (f.string(from: date), 80 + perWeek * Double(i) / 7)
            }
        }
        XCTAssertEqual(DietAdjust.weekly(plan: plan, result: r, weighIns: weights(0.1), loggedDays: 6, today: "2026-11-30").hold, .onPlan)
        XCTAssertEqual(DietAdjust.weekly(plan: plan, result: r, weighIns: weights(0.6), loggedDays: 6, today: "2026-11-30").changeKcal,
                       -DietAdjust.recompStepKcal)
        let lose = DietPlan(goal: .lose, startDay: "2026-11-02", startWeightKg: 80)
        let rl = DietTargets.resolve(lose, person: DietPerson(weightKg: 80, heightCm: 180, age: 40, male: true), burnKcal: 2_500)
        XCTAssertEqual(DietAdjust.weekly(plan: lose, result: rl, weighIns: weights(0), loggedDays: 6, today: "2026-11-30",
                                         phase: .dietBreak).hold, .dietBreak)
    }
}

/// This week's suggestions (owner, 2026-11-10).
final class DietAdviceTests: XCTestCase {
    private func inputs(_ goal: DietPlan.Goal = .lose, protein: Double? = 150, weighIns: Int = 5, logged: Int = 6,
                        strength: Double? = nil, trend: Double? = -0.5, logged21: Int = 18, age: Int = 40,
                        holding: Bool = false) -> DietAdvice.Inputs {
        .init(goal: goal, proteinMeanG: protein, proteinGoalG: 160, weighInsLast7: weighIns, loggedDaysLast7: logged,
              strengthChange4WeeksPercent: strength, trend3WeeksKgPerWeek: trend, loggedDaysLast21: logged21,
              inBreakOrHolding: holding, planAgeDays: age)
    }

    func testAPlanOnTrackGetsNoSuggestion() {
        XCTAssertTrue(DietAdvice.suggestions(inputs()).isEmpty)
    }

    func testEachRuleFires() {
        XCTAssertEqual(DietAdvice.suggestions(inputs(protein: 110)).map(\.kind), [.proteinLow])
        XCTAssertEqual(DietAdvice.suggestions(inputs(weighIns: 1)).map(\.kind), [.weighMore])
        XCTAssertEqual(DietAdvice.suggestions(inputs(logged: 3)).map(\.kind), [.logMore])
        XCTAssertEqual(DietAdvice.suggestions(inputs(trend: 0)).map(\.kind), [.lossStalled])
        XCTAssertEqual(DietAdvice.suggestions(inputs(.gain, strength: 0.2, trend: 0.2)).map(\.kind), [.strengthStalled])
    }

    func testStallsNeedEnoughDataAndTime() {
        XCTAssertTrue(DietAdvice.suggestions(inputs(trend: 0, logged21: 8)).isEmpty, "a stall from sparse logging is no stall")
        XCTAssertTrue(DietAdvice.suggestions(inputs(trend: 0, age: 20)).isEmpty, "too early")
        XCTAssertTrue(DietAdvice.suggestions(inputs(trend: 0, holding: true)).isEmpty)
    }

    func testAtMostThreeAndDismissedStayAway() {
        let all = inputs(protein: 100, weighIns: 0, logged: 3, trend: 0, logged21: 15)
        XCTAssertEqual(DietAdvice.suggestions(all).count, 3)
        XCTAssertFalse(DietAdvice.suggestions(all, dismissed: [.weighMore]).contains { $0.kind == .weighMore })
    }

    func testTakingASuggestionChangesThePlanOnlyWhereItShould() throws {
        let plan = DietPlan(goal: .gain, startDay: "2026-10-01", startWeightKg: 80)
        let more = try XCTUnwrap(DietAdvice.applying(.init(kind: .strengthStalled, action: .addKcal), to: plan, today: "2026-11-10"))
        XCTAssertEqual(more.adjustmentKcal, 100)
        let rest = try XCTUnwrap(DietAdvice.applying(.init(kind: .lossStalled, action: .takeBreakWeek), to: plan, today: "2026-11-10"))
        XCTAssertEqual(rest.breakFromDay, "2026-11-10")
        XCTAssertNil(DietAdvice.applying(.init(kind: .weighMore, action: .openWeight), to: plan, today: "2026-11-10"))
    }
}

/// The coach's proposed plan change (owner, 2026-11-10).
final class DietPlanChangeTests: XCTestCase {
    func testParsingKeepsOnlyWhatThePlannerAllows() {
        let c = DietPlanChange.parse(["goal": "recomp", "pace_percent": 3, "form": "mediterranean",
                                      "day_shift_percent": 12, "diet_break_every_weeks": 40, "rationale": " why "], now: 1)
        XCTAssertEqual(c.goal, .recomp)
        XCTAssertNil(c.pacePercent, "3 % a week is beyond any mode")
        XCTAssertEqual(c.form, .mediterranean)
        XCTAssertEqual(c.dayShift ?? 0, 0.12, accuracy: 1e-9)
        XCTAssertNil(c.dietBreakEveryWeeks)
        XCTAssertEqual(c.rationale, "why")
        XCTAssertTrue(DietPlanChange.parse(["goal": "fly"], now: 1).isEmpty)
    }

    func testApplyingRestartsAGoalAndKeepsTheSafetyLines() throws {
        let plan = DietPlan(goal: .lose, pacePercent: 0.5, goalWeightKg: 80, startDay: "2026-10-01", startWeightKg: 92,
                            adjustmentKcal: -150)
        let next = DietPlanChange(goal: .recomp, rationale: "", createdAt: 0).apply(to: plan, today: "2026-11-10", weightKg: 88)
        XCTAssertEqual(next.goal, .recomp)
        XCTAssertEqual(next.startDay, "2026-11-10")
        XCTAssertEqual(next.startWeightKg, 88)
        XCTAssertEqual(next.adjustmentKcal, 0)
        XCTAssertNil(next.goalWeightKg)
        XCTAssertTrue(next.strength)
        let fast = DietPlanChange(pacePercent: 1.4, rationale: "", createdAt: 0).apply(to: plan, today: "2026-11-10", weightKg: 88)
        XCTAssertEqual(fast.mode, .advanced, "a pace past the simple mode's limit needs the advanced one")
        // A young wearer still gets no deficit, whatever the coach proposed.
        let r = DietTargets.resolve(fast, person: DietPerson(weightKg: 70, heightCm: 175, age: 16, male: true), burnKcal: 2_500)
        XCTAssertEqual(r.goal, .maintain)
        let rest = DietPlanChange(breakWeekNow: true, rationale: "", createdAt: 0).apply(to: plan, today: "2026-11-10", weightKg: 88)
        XCTAssertEqual(DietProgram.phase(on: "2026-11-12", plan: rest, goalReachedDay: nil), .dietBreak)
        let round = try XCTUnwrap(DietPlanChange.decode(DietPlanChange(form: .keto, rationale: "x", createdAt: 5).encoded()))
        XCTAssertEqual(round.form, .keto)
    }
}
