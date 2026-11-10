import XCTest
@testable import StrandCore

/// Active days, the real burn from food and weight, and the way to the goal (owner, 2026-11-10).
final class DietTrackerTests: XCTestCase {
    private func plan(_ goal: DietPlan.Goal = .lose, active: Bool? = true, form: DietForm = .balanced,
                      start: Double = 90, goal goalKg: Double? = 80) -> DietPlan {
        DietPlan(goal: goal, form: form, goalWeightKg: goalKg, startDay: "2026-10-01", startWeightKg: start,
                 activeDays: active)
    }

    private func day(_ offset: Int, from base: String = "2026-11-10") -> String {
        let date = WeightSeries.date(forDay: base)!.addingTimeInterval(Double(offset) * 86_400)
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: Active days

    func testAQuietDayAddsNothing() {
        XCTAssertEqual(DietActiveDay.bonusKcal(plan: plan(), day: "2026-11-09", burnedKcal: 2_400, usualStrapKcal: 2_500,
                                               elapsedFraction: 1), 0)
    }

    func testAnActiveEveningAddsHalfTheExtraSoFar() {
        // At 18:00 three quarters of the day are gone: 1,875 kcal would be usual, 2,275 were burned.
        let bonus = DietActiveDay.bonusKcal(plan: plan(), day: "2026-11-10", burnedKcal: 2_275, usualStrapKcal: 2_500,
                                            elapsedFraction: 0.75)
        XCTAssertEqual(bonus, 200)
    }

    func testAPastDayCountsTheWholeDayAndTheBonusIsCapped() {
        XCTAssertEqual(DietActiveDay.bonusKcal(plan: plan(), day: "2026-11-09", burnedKcal: 3_100, usualStrapKcal: 2_500,
                                               elapsedFraction: 1), 300)
        XCTAssertEqual(DietActiveDay.bonusKcal(plan: plan(), day: "2026-11-09", burnedKcal: 5_000, usualStrapKcal: 2_500,
                                               elapsedFraction: 1), DietActiveDay.maxBonusKcal)
    }

    func testOffManualOrFastingDaysAddNothing() {
        XCTAssertEqual(DietActiveDay.bonusKcal(plan: plan(active: nil), day: "2026-11-09", burnedKcal: 3_100,
                                               usualStrapKcal: 2_500, elapsedFraction: 1), 0)
        var manual = plan(); manual.steering = .manual
        XCTAssertEqual(DietActiveDay.bonusKcal(plan: manual, day: "2026-11-09", burnedKcal: 3_100, usualStrapKcal: 2_500,
                                               elapsedFraction: 1), 0)
        // 5:2 fasts on Monday; 2026-11-09 is a Monday.
        XCTAssertEqual(DietActiveDay.bonusKcal(plan: plan(form: .fasting52), day: "2026-11-09", burnedKcal: 3_100,
                                               usualStrapKcal: 2_500, elapsedFraction: 1), 0)
    }

    func testTheRealBurnScalesTheStrapsExtra() {
        // The strap runs 20 % high: its 600 kcal extra is 480 real, half of that is the bonus.
        XCTAssertEqual(DietActiveDay.bonusKcal(plan: plan(), day: "2026-11-09", burnedKcal: 3_100, usualStrapKcal: 2_500,
                                               elapsedFraction: 1, realToStrap: 0.8), 240)
    }

    func testTheBonusGoesToCarbohydrateAlone() {
        let p = plan()
        let r = DietTargets.resolve(p, person: DietPerson(weightKg: 90, heightCm: 180, age: 40, male: true), burnKcal: 2_500)
        let plain = FoodTargets.macros(plan: p, result: r, day: "2026-11-10")
        let active = FoodTargets.macros(plan: p, result: r, day: "2026-11-10", activeBonusKcal: 200)
        XCTAssertEqual(active.proteinG, plain.proteinG, accuracy: 1e-9)
        XCTAssertEqual(active.fatG, plain.fatG, accuracy: 1e-9)
        XCTAssertEqual(active.carbsG - plain.carbsG, 50, accuracy: 1e-9)
        let kcal = FoodTargets.calories(plan: p, result: r, day: "2026-11-10", activeBonusKcal: 200)
        XCTAssertEqual(kcal.kcal - FoodTargets.calories(plan: p, result: r, day: "2026-11-10").kcal, 200, accuracy: 1e-9)
        XCTAssertEqual(kcal.activeBonusKcal, 200)
    }

    func testElapsedFraction() {
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: WeightSeries.date(forDay: "2026-11-10")!)!
        XCTAssertEqual(DietActiveDay.elapsedFraction(day: "2026-11-10", now: noon), 0.5, accuracy: 0.05)
        XCTAssertEqual(DietActiveDay.elapsedFraction(day: "2026-11-09", now: noon), 1)
        XCTAssertEqual(DietActiveDay.elapsedFraction(day: "2026-11-11", now: noon), 0)
    }

    // MARK: Real burn

    /// A wearer who burns `burn` a day, eats `intake` and so moves `(intake − burn) / 7,700` kg a day.
    private func history(burn: Double, intake: Double, marked: Int, noise: Double = 0) ->
        (intake: [String: Double], complete: Set<String>, weights: [(day: String, kg: Double)]) {
        var intakeByDay: [String: Double] = [:], complete = Set<String>(), weights: [(day: String, kg: Double)] = []
        for i in 0..<28 {
            let d = day(-27 + i)
            intakeByDay[d] = intake
            if i < marked { complete.insert(d) }
            if i % 3 == 0 {
                let kg = 90 + Double(i) * (intake - burn) / 7_700 + (i % 2 == 0 ? noise : -noise)
                weights.append((d, kg))
            }
        }
        return (intakeByDay, complete, weights)
    }

    func testTheRealBurnComesFromFoodAndTheWeightTrend() throws {
        for (burn, intake) in [(2_600.0, 2_100.0), (2_400, 2_900), (2_500, 2_500)] {
            let h = history(burn: burn, intake: intake, marked: 28)
            let strap = Dictionary(uniqueKeysWithValues: h.intake.keys.map { ($0, burn * 1.1) })
            guard case .estimate(let e) = DietExpenditure.estimate(intakeByDay: h.intake, completeDays: h.complete,
                                                                    weighIns: h.weights, strapByDay: strap, today: day(0))
            else { return XCTFail("expected an estimate") }
            XCTAssertEqual(e.burnKcal, burn, accuracy: 1, "intake \(intake)")
            XCTAssertEqual(try XCTUnwrap(e.realToStrap), 1 / 1.1, accuracy: 0.001)
        }
    }

    func testUnmarkedDaysDoNotCountEvenWhenLogged() {
        let h = history(burn: 2_600, intake: 2_100, marked: 10)
        XCTAssertEqual(DietExpenditure.estimate(intakeByDay: h.intake, completeDays: h.complete, weighIns: h.weights,
                                                strapByDay: [:], today: day(0)),
                       .missing(completeDays: 10, weighIns: h.weights.count))
    }

    func testTooFewWeighInsGiveNoFigure() {
        let h = history(burn: 2_600, intake: 2_100, marked: 28)
        let outcome = DietExpenditure.estimate(intakeByDay: h.intake, completeDays: h.complete,
                                               weighIns: Array(h.weights.prefix(4)), strapByDay: [:], today: day(0))
        XCTAssertEqual(outcome, .missing(completeDays: 28, weighIns: 4))
    }

    func testScatteredWeighInsWidenTheRange() throws {
        let calm = history(burn: 2_600, intake: 2_100, marked: 28)
        let noisy = history(burn: 2_600, intake: 2_100, marked: 28, noise: 0.8)
        guard case .estimate(let a) = DietExpenditure.estimate(intakeByDay: calm.intake, completeDays: calm.complete,
                                                                weighIns: calm.weights, strapByDay: [:], today: day(0)),
              case .estimate(let b) = DietExpenditure.estimate(intakeByDay: noisy.intake, completeDays: noisy.complete,
                                                                weighIns: noisy.weights, strapByDay: [:], today: day(0))
        else { return XCTFail("expected estimates") }
        XCTAssertLessThan(a.rangeKcal.upperBound - a.rangeKcal.lowerBound, 1)
        XCTAssertGreaterThan(b.rangeKcal.upperBound - b.rangeKcal.lowerBound, 100)
        XCTAssertNil(b.realToStrap, "no strap figure, no ratio")
    }

    // MARK: Way to the goal

    private func weighIns(_ kgs: [Double]) -> [(day: String, kg: Double)] {
        kgs.enumerated().map { (day(-(kgs.count - 1) + $0.offset), $0.element) }
    }

    func testTheWayDownReachesItsStages() throws {
        let steady = Array(repeating: 87.4, count: 10)
        guard case .way(let w) = DietProgress.resolve(plan: plan(), goalWeightKg: 80, weighIns: weighIns(steady))
        else { return XCTFail("expected a way") }
        XCTAssertEqual(w.fraction, 0.26, accuracy: 0.01)
        XCTAssertEqual(w.stage, .quarter)
        XCTAssertEqual(w.leftKg, 7.4, accuracy: 0.05)
        guard case .way(let done) = DietProgress.resolve(plan: plan(), goalWeightKg: 80,
                                                          weighIns: weighIns(Array(repeating: 79.5, count: 10)))
        else { return XCTFail("expected a way") }
        XCTAssertEqual(done.stage, .goal)
        XCTAssertEqual(done.fraction, 1)
        XCTAssertEqual(done.leftKg, 0)
    }

    func testOneHeavyMorningDoesNotKnockAStageOff() throws {
        let kgs = Array(repeating: 84.3, count: 12) + [86.3]
        guard case .way(let w) = DietProgress.resolve(plan: plan(), goalWeightKg: 80, weighIns: weighIns(kgs))
        else { return XCTFail("expected a way") }
        XCTAssertEqual(w.stage, .half, "the trend, not the last reading")
    }

    func testGainingRunsTheOtherWay() throws {
        guard case .way(let w) = DietProgress.resolve(plan: plan(.gain, start: 70, goal: 76), goalWeightKg: 76,
                                                       weighIns: weighIns(Array(repeating: 74.6, count: 10)))
        else { return XCTFail("expected a way") }
        XCTAssertEqual(w.stage, .threeQuarter)
        XCTAssertEqual(w.doneKg, 4.6, accuracy: 0.05)
    }

    func testHoldingIsARangeAndNoGoalWeightIsNoWay() {
        guard case .hold(let h) = DietProgress.resolve(plan: plan(.maintain, start: 80, goal: nil), goalWeightKg: nil,
                                                        weighIns: weighIns(Array(repeating: 80.4, count: 30)))
        else { return XCTFail("expected holding") }
        XCTAssertTrue(h.inRange)
        XCTAssertGreaterThanOrEqual(h.weeksInRange, 3)
        XCTAssertNil(DietProgress.resolve(plan: plan(goal: nil), goalWeightKg: nil, weighIns: weighIns([88, 87.5])))
        XCTAssertNil(DietProgress.resolve(plan: plan(), goalWeightKg: 80, weighIns: []))
    }
}
