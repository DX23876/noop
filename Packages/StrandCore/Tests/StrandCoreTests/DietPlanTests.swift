import XCTest
@testable import StrandCore
import WhoopStore

final class DietPlanTests: XCTestCase {
    private let big = DietPerson(weightKg: 200, heightCm: 195, age: 35, male: true)
    private let small = DietPerson(weightKg: 52, heightCm: 160, age: 30, male: false)

    private func plan(_ goal: DietPlan.Goal = .lose, pace: Double = 1.0, form: DietForm = .balanced,
                      mode: DietPlan.Mode = .simple, weight: Double = 200) -> DietPlan {
        DietPlan(goal: goal, mode: mode, pacePercent: pace, form: form, startDay: "2026-11-01", startWeightKg: weight)
    }

    // MARK: Targets

    func testALargeBodyMayRunALargeDeficitBoundToItsWeight() {
        let r = DietTargets.resolve(plan(pace: 1.0), person: big, burnKcal: 4_200)
        XCTAssertEqual(r.paceKgPerWeek, -2, accuracy: 0.001)
        XCTAssertEqual(r.dailyDeltaKcal, -2 * 7_700 / 7, accuracy: 0.5)          // 2,200 kcal a day
        XCTAssertEqual(r.averageKcal, 4_200 - 2_200, accuracy: 0.5)
        XCTAssertFalse(r.notes.contains(.floorApplied))
    }

    func testNobodyGoesUnderTheWeeklyFloor() {
        let r = DietTargets.resolve(plan(pace: 1.0, weight: 52), person: small, burnKcal: 1_600)
        XCTAssertEqual(r.averageKcal, 1_200)
        XCTAssertTrue(r.notes.contains(.floorApplied))
    }

    func testThePaceIsCappedByMode() {
        let simple = DietTargets.resolve(plan(pace: 1.4), person: big, burnKcal: 4_200)
        XCTAssertEqual(simple.pacePercent, 1.0)
        XCTAssertTrue(simple.notes.contains(.paceCapped))
        let advanced = DietTargets.resolve(plan(pace: 1.4, mode: .advanced), person: big, burnKcal: 4_200)
        XCTAssertEqual(advanced.pacePercent, 1.4)
        XCTAssertTrue(advanced.notes.contains(.paceAboveRecommended))
        let tooFast = DietTargets.resolve(plan(pace: 3, mode: .advanced), person: big, burnKcal: 4_200)
        XCTAssertEqual(tooFast.pacePercent, 1.5)
    }

    func testFastingDaysKeepTheWeeklyAverage() {
        // Three and a half fasting days at nothing, eating days at 3,000 is about 1,500 on average: allowed.
        var p = plan(form: .alternateDayFull, mode: .advanced)
        p.steering = .manual
        p.fixedKcal = 1_500
        let r = DietTargets.resolve(p, person: big, burnKcal: 4_200)
        XCTAssertEqual(r.fastingDayKcal, 0)
        XCTAssertEqual(r.eatingDayKcal, 3_000, accuracy: 0.5)
        XCTAssertEqual(r.averageKcal * 7, r.eatingDayKcal * 3.5 + 0 * 3.5, accuracy: 1)
    }

    func testFastingDaysFollowAFixedRhythm() {
        let p = plan(form: .alternateDay, mode: .advanced)
        XCTAssertFalse(DietTargets.isFastingDay("2026-11-01", plan: p))
        XCTAssertTrue(DietTargets.isFastingDay("2026-11-02", plan: p))
        XCTAssertFalse(DietTargets.isFastingDay("2026-11-03", plan: p))
        let r = DietTargets.resolve(p, person: big, burnKcal: 4_000)
        XCTAssertEqual(DietTargets.kcal(on: "2026-11-02", plan: p, result: r), 1_000, accuracy: 0.5)
    }

    func testNoDeficitForTheYoungThePregnantAndTheUnderweight() {
        let young = DietTargets.resolve(plan(), person: DietPerson(weightKg: 80, heightCm: 175, age: 16, male: true), burnKcal: 2_600)
        XCTAssertEqual(young.goal, .maintain)
        XCTAssertTrue(young.notes.contains(.youngNoDeficit))
        var pregnant = plan()
        pregnant.pregnantOrNursing = true
        XCTAssertEqual(DietTargets.resolve(pregnant, person: big, burnKcal: 4_000).goal, .maintain)
        let thin = DietTargets.resolve(plan(weight: 45), person: DietPerson(weightKg: 45, heightCm: 170, age: 30, male: false), burnKcal: 1_900)
        XCTAssertTrue(thin.notes.contains(.underweightNoDeficit))
        XCTAssertEqual(thin.averageKcal, 1_900, accuracy: 0.5)
    }

    func testTheGoalWeightStaysAboveBMI18Point5() {
        var p = plan(weight: 60)
        p.goalWeightKg = 40
        let r = DietTargets.resolve(p, person: DietPerson(weightKg: 60, heightCm: 170, age: 30, male: false), burnKcal: 2_000)
        XCTAssertEqual(r.goalWeightKg ?? 0, 53.5, accuracy: 0.1)
        XCTAssertTrue(r.notes.contains(.goalWeightRaised))
    }

    func testProteinUsesTheReferenceWeightAtAHighBMI() {
        let r = DietTargets.resolve(plan(), person: big, burnKcal: 4_200)
        XCTAssertEqual(r.proteinG, 25 * 1.95 * 1.95 * 1.6, accuracy: 0.5)       // not 200 kg × 1.6
        var strong = plan()
        strong.strength = true
        XCTAssertEqual(DietTargets.resolve(strong, person: big, burnKcal: 4_200).proteinG, 25 * 1.95 * 1.95 * 2.0, accuracy: 0.5)
    }

    func testFormsShapeTheMacrosAndAddUpToTheCalories() {
        for form in [DietForm.balanced, .mediterranean, .lowFat, .lowCarb, .keto, .highProtein] {
            let r = DietTargets.resolve(plan(form: form, mode: .advanced), person: big, burnKcal: 4_200)
            XCTAssertEqual(r.proteinG * 4 + r.carbsG * 4 + r.fatG * 9, r.averageKcal, accuracy: 1, "\(form)")
        }
        let keto = DietTargets.resolve(plan(form: .keto, mode: .advanced), person: big, burnKcal: 4_200)
        XCTAssertEqual(keto.carbsG, 25)
        let lowFat = DietTargets.resolve(plan(form: .lowFat), person: big, burnKcal: 4_200)
        let balanced = DietTargets.resolve(plan(), person: big, burnKcal: 4_200)
        XCTAssertLessThan(lowFat.fatG, balanced.fatG)
    }

    func testEffortGrowsWithFormAndPace() {
        let easy = DietTargets.resolve(plan(pace: 0.5), person: big, burnKcal: 4_200)
        XCTAssertEqual(easy.effort, .easy)
        let hard = DietTargets.resolve(plan(pace: 1.5, form: .keto, mode: .advanced), person: big, burnKcal: 4_200)
        XCTAssertEqual(hard.effort, .veryHard)
        var vegan = plan(pace: 0.75, form: .mediterranean)
        vegan.addon = .vegan
        XCTAssertEqual(DietTargets.resolve(vegan, person: big, burnKcal: 4_200).effort, .demanding)
    }

    func testThePlanRoundTripsThroughItsKey() {
        var p = plan(form: .dash)
        p.addon = .pescatarian
        p.keep = [.breadAndPasta]
        XCTAssertEqual(DietPlan.decode(p.encoded()), p)
        XCTAssertNil(DietPlan.decode("not json"))
    }

    // MARK: Forecast

    func testTheForecastFlattensReachesTheGoalAndThenHolds() {
        let f = DietForecast.project(startKg: 200, goalKg: 170, intakeKcal: 2_000, burnKcal: 4_200, weeks: 52)
        let w = f.weeks.map(\.midKg)
        XCTAssertLessThan(w[4], w[0])
        XCTAssertGreaterThan(w[1] - w[2], w[20] - w[21] - 0.0001)   // losing slows down
        let range = try? XCTUnwrap(f.goalWeeks)
        XCTAssertNotNil(range)
        XCTAssertTrue(f.weeks.last!.holding)
        XCTAssertEqual(f.weeks.last!.midKg, 170, accuracy: 0.6)
        for week in f.weeks { XCTAssertLessThanOrEqual(week.lowKg, week.highKg) }
    }

    func testTheBandWidensAndAStrongerDeficitArrivesEarlier() {
        let f = DietForecast.project(startKg: 100, goalKg: 90, intakeKcal: 1_800, burnKcal: 2_600, weeks: 40)
        XCTAssertGreaterThan(f.weeks[10].highKg - f.weeks[10].lowKg, f.weeks[2].highKg - f.weeks[2].lowKg)
        guard let range = f.goalWeeks else { return XCTFail("goal reached") }
        XCTAssertLessThan(range.lowerBound, range.upperBound)
    }

    func testDietBreaksHoldAWeek() {
        let f = DietForecast.project(startKg: 100, goalKg: nil, intakeKcal: 1_800, burnKcal: 2_600, dietBreakEveryWeeks: 4, weeks: 10)
        XCTAssertTrue(f.weeks[5].dietBreak)
        XCTAssertEqual(f.weeks[5].midKg, f.weeks[4].midKg, accuracy: 0.01)
    }

    // MARK: Weekly adjustment

    private func weighIns(from kg: Double, perWeek: Double, endingOn day: Int = 30) -> [(day: String, kg: Double)] {
        (0..<14).map { i in
            let d = day - 13 + i
            return (String(format: "2026-11-%02d", d), kg + perWeek * Double(i) / 7)
        }
    }

    func testLosingSlowerThanPlannedLowersTheCaloriesAtMost150() {
        let p = plan(pace: 1.0)
        let r = DietTargets.resolve(p, person: big, burnKcal: 4_200)
        let o = DietAdjust.weekly(plan: p, result: r, weighIns: weighIns(from: 200, perWeek: -0.5), loggedDays: 7, today: "2026-11-30")
        XCTAssertNil(o.hold)
        XCTAssertEqual(o.changeKcal, -150)
        XCTAssertEqual(o.trendKgPerWeek ?? 0, -0.5, accuracy: 0.01)
    }

    func testLosingFasterRaisesThemAndOnPlanHolds() {
        let p = plan(pace: 0.5, weight: 100)
        let person = DietPerson(weightKg: 100, heightCm: 180, age: 40, male: true)
        let r = DietTargets.resolve(p, person: person, burnKcal: 2_800)
        let faster = DietAdjust.weekly(plan: p, result: r, weighIns: weighIns(from: 100, perWeek: -0.6), loggedDays: 6, today: "2026-11-30")
        XCTAssertGreaterThan(faster.changeKcal, 0)
        let onPlan = DietAdjust.weekly(plan: p, result: r, weighIns: weighIns(from: 100, perWeek: -0.5), loggedDays: 6, today: "2026-11-30")
        XCTAssertEqual(onPlan.hold, .onPlan)
    }

    func testTheWeekIsNotTrustedWithoutDataOrTooEarly() {
        let p = plan()
        let r = DietTargets.resolve(p, person: big, burnKcal: 4_200)
        XCTAssertEqual(DietAdjust.weekly(plan: p, result: r, weighIns: weighIns(from: 200, perWeek: 0), loggedDays: 7, today: "2026-11-10").hold, .tooEarly)
        XCTAssertEqual(DietAdjust.weekly(plan: p, result: r, weighIns: weighIns(from: 200, perWeek: 0), loggedDays: 4, today: "2026-11-30").hold, .fewLoggedDays)
        XCTAssertEqual(DietAdjust.weekly(plan: p, result: r, weighIns: [("2026-11-29", 199)], loggedDays: 7, today: "2026-11-30").hold, .fewWeighIns)
        var recent = p
        recent.lastAdjustedDay = "2026-11-27"
        XCTAssertEqual(DietAdjust.weekly(plan: recent, result: r, weighIns: weighIns(from: 200, perWeek: 0), loggedDays: 7, today: "2026-11-30").hold, .notAWeekYet)
        var manual = p
        manual.steering = .manual
        XCTAssertEqual(DietAdjust.weekly(plan: manual, result: r, weighIns: weighIns(from: 200, perWeek: 0), loggedDays: 7, today: "2026-11-30").hold, .manualSteering)
    }

    // MARK: Suggestions and fit

    func testSuggestionsStartFromTheLogAndRespectWhatTheWearerKeeps() {
        let lowCarbWeek = (0..<6).map { _ in FoodLogEntryLite(proteinG: 120, carbsG: 60, fatG: 130) }
        let s = DietSuggest.top(entries: lowCarbWeek, keep: [], likesRules: false, strength: false, mode: .simple)
        XCTAssertEqual(s.first?.form, .lowCarb)
        XCTAssertEqual(s.first?.reason, .closestToYourLog)
        XCTAssertEqual(s.count, 3)
        let keepsBread = DietSuggest.top(entries: lowCarbWeek, keep: [.breadAndPasta], likesRules: false, strength: false, mode: .simple)
        XCTAssertFalse(keepsBread.contains { $0.form == .lowCarb || $0.form == .keto })
        let simple = DietSuggest.top(entries: [], keep: [], likesRules: true, strength: true, mode: .simple)
        XCTAssertFalse(simple.contains { $0.form.advancedOnly })
        XCTAssertEqual(simple.first?.form, .highProtein)
    }

    func testFoodsFitTheFormAndTheAddon() {
        XCTAssertEqual(DietForm.lowCarb.fit(.bread, addon: nil), -1)
        XCTAssertEqual(DietForm.mediterranean.fit(.fish, addon: nil), 1)
        XCTAssertEqual(DietForm.mediterranean.fit(.fish, addon: .vegetarian), -1)
        XCTAssertEqual(DietForm.balanced.fit(.dairy, addon: .vegan), -1)
        XCTAssertFalse(DietAddon.vegan.fits(.keto))
    }

    func testFoodTargetsReadThePlanForEachDay() {
        let p = plan(form: .fasting52, mode: .advanced)
        let r = DietTargets.resolve(p, person: big, burnKcal: 4_200)
        let monday = FoodTargets.calories(plan: p, result: r, day: "2026-11-02")
        let tuesday = FoodTargets.calories(plan: p, result: r, day: "2026-11-03")
        XCTAssertEqual(monday.kcal, 1_050, accuracy: 0.5)
        XCTAssertEqual(tuesday.kcal, r.eatingDayKcal, accuracy: 0.5)
        XCTAssertEqual(monday.basis, .plan)
        let m = FoodTargets.macros(plan: p, result: r, day: "2026-11-03")
        XCTAssertEqual(m.proteinG * 4 + m.carbsG * 4 + m.fatG * 9, tuesday.kcal, accuracy: 1)
    }

    /// The JSON Android's `CoreDietPlan.Plan.json()` writes (optional fields left out), so both apps read one plan.
    func testAKotlinPlanDecodes() throws {
        let kotlin = #"{"goal":"lose","mode":"advanced","pacePercent":0.75,"form":"fasting52","addon":"pescatarian","strength":true,"goalWeightKg":180,"steering":"coached","keep":["breadAndPasta"],"startDay":"2026-11-09","startWeightKg":200,"adjustmentKcal":0,"hideNumbers":false,"pregnantOrNursing":false}"#
        let plan = try XCTUnwrap(DietPlan.decode(kotlin))
        XCTAssertEqual(plan.form, .fasting52)
        XCTAssertEqual(plan.addon, .pescatarian)
        XCTAssertNil(plan.fixedKcal)
    }
}
