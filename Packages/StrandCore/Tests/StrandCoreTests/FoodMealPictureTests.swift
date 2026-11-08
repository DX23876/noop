import XCTest
@testable import StrandCore
import WhoopStore

final class FoodMealPictureTests: XCTestCase {
    private func date(_ day: String, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: WeightSeries.date(forDay: day)!)!
    }

    private func food(_ id: String, kcal: Double = 100) -> FoodItem {
        FoodItem(id: id, source: id.hasPrefix("bls:") ? .bls : .off, name: id, per100g: NutrientAmounts([.energyKcal: kcal]))
    }

    private func eat(_ id: String, _ day: String, _ hour: Int, grams: Double = 100, kcal: Double = 100) -> FoodLogEntry {
        FoodLog.entry(for: food(id, kcal: kcal), grams: grams, at: date(day, hour), origin: .search)
    }

    // MARK: Motifs

    func testBlsLettersAndRecipesNameTheirMotif() {
        XCTAssertEqual(FoodGroupMotif.forFoodId("bls:B100000"), .bread)
        XCTAssertEqual(FoodGroupMotif.forFoodId("bls:C133000"), .grains)    // oats are not a loaf
        XCTAssertEqual(FoodGroupMotif.forFoodId("bls:T410100"), .fish)
        XCTAssertEqual(FoodGroupMotif.forFoodId("bls:W100000"), .meat)
        XCTAssertEqual(FoodGroupMotif.forFoodId("bls:V420000"), .poultry)   // chicken is not shown as steak
        XCTAssertEqual(FoodGroupMotif.forFoodId("recipe:abc"), .dishes)
        XCTAssertNil(FoodGroupMotif.forFoodId("bls:R100000"))          // salt and spices have no picture
        XCTAssertNil(FoodGroupMotif.forFoodId("off:4000000000017"))    // needs its stored group
    }

    func testOpenFoodFactsGroupsPreferTheDrinkOrSweetOverTheIngredient() {
        XCTAssertEqual(FoodGroupMotif.forGroup("fruit-juices"), .drinks)
        XCTAssertEqual(FoodGroupMotif.forGroup("dairy-desserts"), .sweets)
        XCTAssertEqual(FoodGroupMotif.forGroup("fruits"), .fruit)
        XCTAssertEqual(FoodGroupMotif.forGroup("fatty-fish"), .fish)
        XCTAssertEqual(FoodGroupMotif.forGroup("cheese"), .dairy)
        XCTAssertEqual(FoodGroupMotif.forGroup("poultry"), .poultry)
        XCTAssertEqual(FoodGroupMotif.forGroup("processed-meat"), .meat)
        XCTAssertEqual(FoodGroupMotif.forGroup("G"), .vegetables)
        XCTAssertNil(FoodGroupMotif.forGroup(""))
        XCTAssertNil(FoodGroupMotif.forGroup(nil))
    }

    func testAMealShowsTheGroupWithTheMostCalories() {
        let bread = eat("bls:B100000", "2026-11-08", 8, grams: 100, kcal: 250)
        let butter = eat("bls:Q100000", "2026-11-08", 8, grams: 10, kcal: 740)
        let juice = eat("off:1", "2026-11-08", 8, grams: 200, kcal: 45)
        XCTAssertEqual(FoodGroupMotif.forMeal([bread, butter, juice], groups: ["off:1": "fruit-juices"]), .bread)
        XCTAssertEqual(FoodGroupMotif.forMeal([butter, juice], groups: ["off:1": "fruit-juices"]), .drinks)
        XCTAssertNil(FoodGroupMotif.forMeal([FoodLog.quickEntry(name: "Canteen", kcal: 600, at: date("2026-11-08", 12))]))
    }

    // MARK: As usual

    func testAHabitOnThreeOfSevenDaysIsOfferedAtItsTime() throws {
        let history = ["2026-11-03", "2026-11-05", "2026-11-07"].flatMap { day in
            [eat("bls:C133000", day, 7), eat("bls:M111100", day, 7)]
        } + [eat("bls:B100000", "2026-11-06", 7)]
        let offer = try XCTUnwrap(FoodRepeat.suggestion(history: history, todayEntries: [], today: "2026-11-08",
                                                         now: date("2026-11-08", 7, 30)))
        XCTAssertEqual(offer.kind, .breakfast)
        XCTAssertEqual(offer.days, 3)
        XCTAssertEqual(Set(offer.entries.compactMap(\.foodId)), ["bls:C133000", "bls:M111100"])
        XCTAssertTrue(offer.entries.allSatisfy { $0.day == "2026-11-07" })   // the most recent time
    }

    func testNoOfferForTwoDaysAnotherMealTimeOrAMealAlreadyEaten() {
        let twice = ["2026-11-05", "2026-11-07"].map { eat("bls:C133000", $0, 7) }
        XCTAssertNil(FoodRepeat.suggestion(history: twice, todayEntries: [], today: "2026-11-08", now: date("2026-11-08", 7)))
        let habit = ["2026-11-03", "2026-11-05", "2026-11-07"].map { eat("bls:C133000", $0, 7) }
        XCTAssertNil(FoodRepeat.suggestion(history: habit, todayEntries: [], today: "2026-11-08", now: date("2026-11-08", 13)))
        XCTAssertNil(FoodRepeat.suggestion(history: habit, todayEntries: [eat("bls:B100000", "2026-11-08", 6)],
                                           today: "2026-11-08", now: date("2026-11-08", 8)))
    }

    func testOldDaysAndVaryingMealsDoNotMakeAHabit() {
        let old = ["2026-10-20", "2026-10-22", "2026-10-24"].map { eat("bls:C133000", $0, 7) }
        XCTAssertNil(FoodRepeat.suggestion(history: old, todayEntries: [], today: "2026-11-08", now: date("2026-11-08", 7)))
        let varied = [("2026-11-03", "bls:C133000"), ("2026-11-05", "bls:B100000"), ("2026-11-07", "bls:E111000")]
            .map { eat($0.1, $0.0, 7) }
        XCTAssertNil(FoodRepeat.suggestion(history: varied, todayEntries: [], today: "2026-11-08", now: date("2026-11-08", 7)))
    }
}
