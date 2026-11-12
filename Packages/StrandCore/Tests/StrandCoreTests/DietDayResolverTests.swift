import XCTest
@testable import StrandCore

/// One resolver for a plan's day (Android parity, 2026-11-12): it must give what the separate steps give.
final class DietDayResolverTests: XCTestCase {
    private let person = DietPerson(weightKg: 90, heightCm: 180, age: 40, male: true)

    private func inputs(_ plan: DietPlan, burned: [String: Double] = [:]) -> DietDayResolver.Inputs {
        DietDayResolver.Inputs(plan: plan, person: person, strapBurnKcal: 2_500, kcalPerKg: nil, burnedByDay: burned,
                               completeDays: [], intakeByDay: [:], weighIns: [], training: .init(), today: "2026-11-10")
    }

    func testAnActivePastDayCarriesItsExtraIntoCaloriesAndCarbohydrate() {
        let plan = DietPlan(goal: .lose, goalWeightKg: 80, startDay: "2026-10-01", startWeightKg: 90, activeDays: true)
        let quiet = DietDayResolver.resolve(inputs(plan), day: "2026-11-09")
        let active = DietDayResolver.resolve(inputs(plan, burned: ["2026-11-09": 3_100]), day: "2026-11-09")
        XCTAssertEqual(quiet.activeBonusKcal, 0)
        XCTAssertEqual(active.activeBonusKcal, 300)
        XCTAssertEqual(active.calories.kcal - quiet.calories.kcal, 300, accuracy: 0.001)
        XCTAssertEqual(active.macros.carbsG - quiet.macros.carbsG, 75, accuracy: 0.001)
        XCTAssertEqual(active.macros.proteinG, quiet.macros.proteinG, accuracy: 0.001)
    }

    func testMatchesTheStepsItReplaces() {
        let plan = DietPlan(goal: .lose, goalWeightKg: 80, startDay: "2026-10-01", startWeightKg: 90)
        let day = DietDayResolver.resolve(inputs(plan), day: "2026-11-10")
        let result = DietTargets.resolve(plan, person: person, burnKcal: 2_500)
        XCTAssertEqual(day.phase, .main)
        XCTAssertEqual(day.planBurnKcal, 2_500)
        XCTAssertEqual(day.calories.kcal, FoodTargets.calories(plan: plan, result: result, day: "2026-11-10").kcal, accuracy: 0.001)
        if case .estimate = day.expenditure { XCTFail("no logged days, so no real burn") }
    }
}
