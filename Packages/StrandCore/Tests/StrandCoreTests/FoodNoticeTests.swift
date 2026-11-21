import XCTest
@testable import StrandCore
import WhoopStore

final class FoodNoticeTests: XCTestCase {
    func testMondayLooksBackOnTheWeekAndTheFirstOnTheMonth() {
        XCTAssertEqual(FoodNotice.morningKind(today: "2026-11-23"), .week, "a Monday")
        XCTAssertEqual(FoodNotice.morningKind(today: "2026-11-24"), .day)
        XCTAssertEqual(FoodNotice.morningKind(today: "2026-12-01"), .month, "the first wins over a Tuesday")
        XCTAssertEqual(FoodNotice.morningKind(today: "2026-06-01"), .month, "and over a Monday")
    }

    func testADayLooksBackWithoutTheWeeklyFoods() {
        let parts = [FoodScore.Part(component: .fishOmega3, points: 0, amountPerDay: 0),
                     FoodScore.Part(component: .vegetables, points: 9, amountPerDay: 4.5),
                     FoodScore.Part(component: .sodium, points: 3, amountPerDay: 3_500)]
        let note = FoodQuality.Note(day: "2026-11-20", span: 1, score: 6, parts: parts, loggedDays: 1, placedShare: 1,
                                    processedShare: nil, provisional: false)
        let day = FoodNotice.recap(kind: .day, note: note, previous: nil, goal: .inRange, badges: [])
        XCTAssertEqual(day.strongest, .vegetables)
        XCTAssertEqual(day.weakest, .sodium, "fish is a weekly food, not the day's news")
        let week = FoodNotice.recap(kind: .week, note: note, previous: nil, goal: nil, badges: [])
        XCTAssertEqual(week.weakest, .fishOmega3)
    }

    func testTheEveningSpeaksOnlyWhenAMealCanCloseTheGap() {
        XCTAssertNil(FoodNotice.eveningGap(proteinEatenG: 140, proteinGoalG: 150, vegetableGrams: 300), "10 g is not worth a push")
        XCTAssertEqual(FoodNotice.eveningGap(proteinEatenG: 110, proteinGoalG: 150, vegetableGrams: 300)?.proteinG, 40)
        XCTAssertNil(FoodNotice.eveningGap(proteinEatenG: 40, proteinGoalG: 150, vegetableGrams: 300)?.proteinG,
                     "110 g is more than one meal")
        XCTAssertEqual(FoodNotice.eveningGap(proteinEatenG: 150, proteinGoalG: 150, vegetableGrams: 80)?.vegetablePortions, 1)
    }

    func testTheEveningIsThreeHoursBeforeBedButNotBeforeFive() {
        XCTAssertEqual(FoodNotice.eveningTime(usualBedtime: DateComponents(hour: 23, minute: 30)), DateComponents(hour: 20, minute: 30))
        XCTAssertEqual(FoodNotice.eveningTime(usualBedtime: DateComponents(hour: 1, minute: 0)), DateComponents(hour: 22, minute: 0))
        XCTAssertEqual(FoodNotice.eveningTime(usualBedtime: DateComponents(hour: 19, minute: 0)), DateComponents(hour: 17, minute: 0))
    }
}
