import XCTest
@testable import StrandCore

/// The one order a day's calorie goal is resolved in (`FoodTargets.dayGoal`).
///
/// It exists because the order used to be written out per screen: the iPhone's Food page skipped the middle
/// step and Android's did not, so a wearer with a plan whose day could not be resolved could read two
/// different goals on two phones. The Today tile now asks the same function, which is the whole point.
final class FoodDayGoalTests: XCTestCase {

    private func calories(_ kcal: Double, _ basis: FoodTargets.CalorieBasis) -> FoodTargets.Calories {
        FoodTargets.Calories(kcal: kcal, burnKcal: 2_600, planDeltaKcal: 0, basis: basis, activeBonusKcal: nil)
    }
    private func goal(_ kcal: Double, _ basis: FoodTargets.CalorieBasis = .plan) -> FoodTargets.DayGoal {
        FoodTargets.DayGoal(calories: calories(kcal, basis), macros: nil)
    }

    func testThePlansOwnDayOutranksEverything() {
        let resolved = FoodTargets.dayGoal(planDay: goal(2_100), planResolved: goal(2_300),
                                           fixedKcal: 1_900, energyPlan: calories(2_500, .plan))
        XCTAssertEqual(resolved?.calories.kcal, 2_100, "the day knows its phase, its shift and its extra")
    }

    func testThePlanWithoutItsDayComesNext() {
        let resolved = FoodTargets.dayGoal(planDay: nil, planResolved: goal(2_300),
                                           fixedKcal: 1_900, energyPlan: calories(2_500, .plan))
        XCTAssertEqual(resolved?.calories.kcal, 2_300)
    }

    func testTheWearersFixedGoalOutranksTheEnergyPlan() {
        let resolved = FoodTargets.dayGoal(planDay: nil, planResolved: nil,
                                           fixedKcal: 1_900, energyPlan: calories(2_500, .plan))
        XCTAssertEqual(resolved?.calories.kcal, 1_900)
        XCTAssertEqual(resolved?.calories.basis, .fixed)
    }

    func testTheEnergyPlanIsTheLastAnswer() {
        let resolved = FoodTargets.dayGoal(planDay: nil, planResolved: nil, fixedKcal: 0,
                                           energyPlan: calories(2_500, .plan))
        XCTAssertEqual(resolved?.calories.kcal, 2_500)
    }

    /// Nothing to answer with is not a goal of nothing: the tile then shows what was eaten and no goal.
    func testNoGoalAtAllAnswersNil() {
        XCTAssertNil(FoodTargets.dayGoal(planDay: nil, planResolved: nil, fixedKcal: 0, energyPlan: nil))
    }

    /// The base goal carries the wearer's own split, since the plan is not there to carry it.
    func testTheBaseGoalSplitsTheCaloriesTheWearersWay() throws {
        let resolved = FoodTargets.dayGoal(planDay: nil, planResolved: nil, fixedKcal: 2_000, energyPlan: nil,
                                           proteinPercent: 30, carbsPercent: 40, fatPercent: 30)
        let macros = try XCTUnwrap(resolved?.macros)
        XCTAssertEqual(macros.proteinG, 2_000 * 0.3 / 4, accuracy: 0.001)
        XCTAssertEqual(macros.fatG, 2_000 * 0.3 / 9, accuracy: 0.001)
    }
}
