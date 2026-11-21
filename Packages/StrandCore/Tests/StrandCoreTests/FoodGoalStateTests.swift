import XCTest
@testable import StrandCore

final class FoodGoalStateTests: XCTestCase {
    private let goals = FoodGoalState.Goals(kcal: 2_000, proteinG: 150, carbCapG: nil, floorKcal: 1_600)

    func testADayIsGenerousAroundTheGoal() {
        XCTAssertEqual(FoodGoalState.day(kcal: 2_290, proteinG: 150, carbsG: 0, goals: goals).energy, .inRange)
        XCTAssertEqual(FoodGoalState.day(kcal: 2_310, proteinG: 150, carbsG: 0, goals: goals).energy, .over)
        XCTAssertEqual(FoodGoalState.day(kcal: 1_710, proteinG: 150, carbsG: 0, goals: goals).energy, .inRange)
    }

    func testBelowTheFloorNeverCountsAsKept() {
        // 1,650 is within 15 % of a 1,900 goal, but under a floor of 1,700 it is not kept.
        let low = FoodGoalState.Goals(kcal: 1_900, proteinG: nil, carbCapG: nil, floorKcal: 1_700)
        let day = FoodGoalState.day(kcal: 1_650, proteinG: 0, carbsG: 0, goals: low)
        XCTAssertEqual(day.energy, .belowFloor)
        XCTAssertFalse(day.kept)
        XCTAssertEqual(FoodGoalState.week(dailyKcal: Array(repeating: 1_650, count: 7), goals: low)?.energy, .belowFloor)
    }

    func testTheFloorIsTheHigherOfBasalAndTheFixedValue() {
        XCTAssertEqual(FoodGoalState.floorKcal(basalKcal: 1_850, male: true), 1_850)
        XCTAssertEqual(FoodGoalState.floorKcal(basalKcal: 1_100, male: false), 1_200)
        XCTAssertEqual(FoodGoalState.floorKcal(basalKcal: nil, male: nil), 1_500, "unknown sex takes the stricter floor")
    }

    func testProteinAndTheKetoCapBelongToKept() {
        let keto = FoodGoalState.Goals(kcal: 2_000, proteinG: 150, carbCapG: 25, floorKcal: 1_500)
        XCTAssertTrue(FoodGoalState.day(kcal: 2_000, proteinG: 140, carbsG: 20, goals: keto).kept)
        XCTAssertFalse(FoodGoalState.day(kcal: 2_000, proteinG: 120, carbsG: 20, goals: keto).kept, "under 90 % protein")
        XCTAssertFalse(FoodGoalState.day(kcal: 2_000, proteinG: 150, carbsG: 40, goals: keto).kept, "over the carb cap")
    }

    func testTheWeekNeedsFiveDaysAndReadsTheMean() {
        XCTAssertNil(FoodGoalState.week(dailyKcal: [2_000, 2_000, 2_000, 2_000], goals: goals))
        let week = FoodGoalState.week(dailyKcal: [2_600, 1_800, 1_900, 2_000, 1_800], goals: goals)
        XCTAssertEqual(week?.energy, .inRange, "one big day inside a good week still keeps the week")
    }

    func testLoggingWarnsOnlyWhenLosingAndClearlyOver() {
        XCTAssertEqual(FoodGoalState.overWarning(dayKcal: 1_200, adding: 1_300, goalKcal: 2_000, losing: true), 2_500)
        XCTAssertNil(FoodGoalState.overWarning(dayKcal: 1_200, adding: 1_100, goalKcal: 2_000, losing: true), "2,300 is within 20 %")
        XCTAssertNil(FoodGoalState.overWarning(dayKcal: 1_200, adding: 1_300, goalKcal: 2_000, losing: false))
    }
}
