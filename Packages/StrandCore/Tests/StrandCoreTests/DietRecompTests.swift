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
        let split = try! XCTUnwrap(DietTargets.trainingAndRestKcal(plan: p, result: r))
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
        XCTAssertTrue(DietTargets.isTrainingDay(tuesday, plan: p, strengthDays: [tuesday]))
        XCTAssertEqual(DietTargets.kcal(on: tuesday, plan: p, result: r, strengthDays: [tuesday]), r.eatingDayKcal * 1.1, accuracy: 0.5)
        XCTAssertEqual(DietActiveDay.bonusKcal(plan: p, day: tuesday, burnedKcal: 3_400, usualStrapKcal: 2_600,
                                               elapsedFraction: 1, strengthDays: [tuesday]), 0)
        XCTAssertGreaterThan(DietActiveDay.bonusKcal(plan: p, day: tuesday, burnedKcal: 3_400, usualStrapKcal: 2_600,
                                                     elapsedFraction: 1), 0, "a rest day keeps its bonus")
    }

    func testShiftOnlyInAdvancedForOtherGoalsAndNeverWithFasting() {
        var lose = DietPlan(goal: .lose, startDay: "2026-11-02", startWeightKg: 85)
        lose.trainingWeekdays = [2]; lose.dayShift = 0.15
        XCTAssertEqual(lose.effectiveDayShift, 0, "the simple mode keeps days even")
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
        XCTAssertEqual(plan.effectiveDayShift, 0)
    }
}
