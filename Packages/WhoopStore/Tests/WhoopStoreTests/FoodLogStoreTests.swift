import XCTest
import GRDB
@testable import WhoopStore

final class FoodLogStoreTests: XCTestCase {
    private func entry(_ id: String, day: String = "2026-11-08", at: Int = 1_000, kcal: Double = 300,
                       protein: Double? = 20, grams: Double? = 150, foodId: String? = "bls:C133000") -> FoodLogEntry {
        var totals: FoodNutrientValues = ["energy_kcal": kcal]
        if let protein { totals["protein_g"] = protein }
        return FoodLogEntry(id: id, loggedAt: at, day: day, foodId: foodId, name: "Haferflocken", grams: grams,
                            per100g: grams.map { _ in ["energy_kcal": 200] }, totals: totals, origin: .search,
                            createdAt: at, updatedAt: at)
    }

    private func dayTotals(_ store: WhoopStore, _ day: String) async throws -> [String: Double] {
        var out: [String: Double] = [:]
        for pair in WhoopStore.foodLogDayKeys {
            if let point = try await store.metricSeries(deviceId: WhoopStore.foodLogSourceId, key: pair.key,
                                                        from: day, to: day).first {
                out[pair.key] = point.value
            }
        }
        return out
    }

    func testEntriesRoundTripAndBankTheDayTotal() async throws {
        let store = try await WhoopStore.inMemory()
        let first = entry("a", at: 1_000), second = entry("b", at: 2_000, kcal: 120, protein: nil)
        let saved = try await store.saveFoodLogEntries([second, first])
        XCTAssertTrue(saved)
        let entries = try await store.foodLogEntries(from: "2026-11-08", to: "2026-11-08")
        XCTAssertEqual(entries, [first, second])
        let totals = try await dayTotals(store, "2026-11-08")
        XCTAssertEqual(totals, ["calories_in": 420, "protein_g": 20])   // carbs and fat stay unknown
    }

    func testMovingAnEntryReBanksBothDays() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveFoodLogEntries([entry("a"), entry("b", kcal: 100)])
        var moved = entry("a")
        moved.day = "2026-11-07"
        try await store.saveFoodLogEntries([moved])
        let today = try await dayTotals(store, "2026-11-08"), yesterday = try await dayTotals(store, "2026-11-07")
        XCTAssertEqual(today["calories_in"], 100)
        XCTAssertEqual(yesterday["calories_in"], 300)
    }

    func testDeletingTheLastEntryClearsTheDayAndReturnsIt() async throws {
        let store = try await WhoopStore.inMemory()
        var withHealth = entry("a")
        withHealth.healthId = "HK-1"
        try await store.saveFoodLogEntries([withHealth])
        let removed = try await store.deleteFoodLogEntries(ids: ["a"])
        XCTAssertEqual(removed.map(\.healthId), ["HK-1"])
        let totals = try await dayTotals(store, "2026-11-08")
        XCTAssertTrue(totals.isEmpty)
    }

    func testInvalidEntriesWriteNothing() async throws {
        let store = try await WhoopStore.inMemory()
        var noName = entry("a"); noName.name = "  "
        var negative = entry("b"); negative.totals = ["energy_kcal": -5]
        var noGrams = entry("c"); noGrams.grams = 0
        for bad in [noName, negative, noGrams] {
            let saved = try await store.saveFoodLogEntries([entry("ok"), bad])
            XCTAssertFalse(saved)
        }
        let entries = try await store.foodLogEntries(from: "2000-01-01", to: "2100-01-01")
        XCTAssertTrue(entries.isEmpty)
    }

    func testAQuickZeroEntryBanksARealZero() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveFoodLogEntries([entry("w", kcal: 0, protein: nil, grams: nil, foodId: nil)])
        let totals = try await dayTotals(store, "2026-11-08")
        XCTAssertEqual(totals, ["calories_in": 0])
    }

    func testRecentFoodsAreOnePerFoodNewestFirst() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveFoodLogEntries([
            entry("a", at: 1_000, foodId: "bls:A"), entry("b", at: 3_000, foodId: "bls:B"),
            entry("c", at: 5_000, foodId: "bls:A"), entry("q", at: 6_000, grams: nil, foodId: nil),
        ])
        let recent = try await store.recentFoods(limit: 10)
        XCTAssertEqual(recent.map(\.foodId), ["bls:A", "bls:B"])
        XCTAssertEqual(recent.first?.timesLogged, 2)
        XCTAssertEqual(recent.first?.lastLoggedAt, 5_000)
    }

    func testAKeptDrinkKeepsItsPackage() async throws {
        let store = try await WhoopStore.inMemory()
        let cans = CustomFood(id: "own:cola", name: "Cola", per100g: ["energy_kcal": 42], origin: .online,
                              createdAt: 1, updatedAt: 1, liquid: true, packageAmount: 330, packageCount: 6)
        let saved = try await store.saveCustomFood(cans)
        XCTAssertTrue(saved)
        let read = try await store.customFood(id: "own:cola")
        XCTAssertEqual(read, cans, "millilitres and the six-pack come back as saved")
        let refused = try await store.saveCustomFood(CustomFood(id: "own:x", name: "x", per100g: [:], origin: .own,
                                                                createdAt: 1, updatedAt: 1, packageAmount: 0))
        XCTAssertFalse(refused, "a package of nothing is not stored")
    }

    func testCustomFoodsRecipesAndFavourites() async throws {
        let store = try await WhoopStore.inMemory()
        let muesli = CustomFood(id: "own:1", name: "Müsli", barcode: "4000000000017", per100g: ["energy_kcal": 430],
                                origin: .label, createdAt: 1, updatedAt: 1)
        let savedFood = try await store.saveCustomFood(muesli)
        XCTAssertTrue(savedFood)
        let byBarcode = try await store.customFood(barcode: "4000000000017")
        XCTAssertEqual(byBarcode, muesli)

        let recipe = FoodRecipe(id: "r1", name: "Porridge", servings: 2, items: [
            .init(foodId: "bls:C133000", name: "Haferflocken", grams: 80, per100g: ["energy_kcal": 348]),
            .init(foodId: nil, name: "Milch", grams: 300, per100g: ["energy_kcal": 64]),
        ], createdAt: 1, updatedAt: 1)
        let savedRecipe = try await store.saveFoodRecipe(recipe)
        XCTAssertTrue(savedRecipe)
        let recipes = try await store.foodRecipes()
        XCTAssertEqual(recipes, [recipe])

        try await store.setFoodFavourite(.init(foodId: "own:1", name: "Müsli", addedAt: 5), on: true)
        let favourites = try await store.foodFavourites()
        XCTAssertEqual(favourites.map(\.foodId), ["own:1"])
        try await store.setFoodFavourite(.init(foodId: "own:1", name: "Müsli", addedAt: 5), on: false)
        let none = try await store.foodFavourites()
        XCTAssertTrue(none.isEmpty)
    }

    func testSavedMealsKeepTheirFoodsInOrderNewestFirst() async throws {
        let store = try await WhoopStore.inMemory()
        let breakfast = FoodSavedMeal(id: "m1", name: "Frühstück", items: [
            .init(foodId: "bls:C133000", name: "Haferflocken", grams: 80, per100g: ["energy_kcal": 348]),
            .init(foodId: nil, name: "Milch", grams: 300, per100g: ["energy_kcal": 64]),
        ], createdAt: 1, updatedAt: 1)
        let lunch = FoodSavedMeal(id: "m2", name: "Mittag", items: [
            .init(foodId: "bls:G000000", name: "Brokkoli", grams: 200, per100g: ["energy_kcal": 35]),
        ], createdAt: 2, updatedAt: 2)
        let savedBreakfast = try await store.saveFoodMeal(breakfast)
        let savedLunch = try await store.saveFoodMeal(lunch)
        XCTAssertTrue(savedBreakfast && savedLunch)
        let meals = try await store.foodMeals()
        XCTAssertEqual(meals, [lunch, breakfast])

        // Saving again under the same id replaces the items instead of adding to them.
        var renamed = breakfast
        renamed.name = "Porridge"
        renamed.items = [breakfast.items[0]]
        renamed.updatedAt = 3
        try await store.saveFoodMeal(renamed)
        let afterRename = try await store.foodMeals()
        XCTAssertEqual(afterRename, [renamed, lunch])

        let deleted = try await store.deleteFoodMeal(id: "m2")
        XCTAssertTrue(deleted)
        let left = try await store.foodMeals()
        XCTAssertEqual(left.map(\.id), ["m1"])
    }

    func testASavedMealWithoutNameOrAmountIsRefused() async throws {
        let store = try await WhoopStore.inMemory()
        let item = FoodRecipe.Item(foodId: nil, name: "Apfel", grams: 150, per100g: ["energy_kcal": 52])
        let noName = try await store.saveFoodMeal(.init(id: "a", name: "  ", items: [item], createdAt: 1, updatedAt: 1))
        let noItems = try await store.saveFoodMeal(.init(id: "b", name: "Snack", items: [], createdAt: 1, updatedAt: 1))
        var zero = item
        zero.grams = 0
        let noAmount = try await store.saveFoodMeal(.init(id: "c", name: "Snack", items: [zero], createdAt: 1, updatedAt: 1))
        XCTAssertFalse(noName || noItems || noAmount)
        let meals = try await store.foodMeals()
        XCTAssertTrue(meals.isEmpty)
    }

    func testCompletelyLoggedDaysAreMarkedAndUnmarked() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.setFoodDayComplete("2026-11-08", true, at: 10)
        try await store.setFoodDayComplete("2026-11-09", true, at: 11)
        try await store.setFoodDayComplete("2026-11-08", true, at: 12)
        let both = try await store.foodCompleteDays(from: "2026-11-01", to: "2026-11-30")
        XCTAssertEqual(both, ["2026-11-08", "2026-11-09"], "marking twice keeps one row")
        let one = try await store.foodCompleteDays(from: "2026-11-09", to: "2026-11-09")
        XCTAssertEqual(one, ["2026-11-09"])
        try await store.setFoodDayComplete("2026-11-09", false)
        let left = try await store.foodCompleteDays(from: "2026-11-01", to: "2026-11-30")
        XCTAssertEqual(left, ["2026-11-08"])
    }

    func testNutrientJsonIsStable() {
        let json = WhoopStore.encodeNutrients(["protein_g": 1.5, "energy_kcal": 100, "bad": .nan])
        XCTAssertEqual(json, #"{"energy_kcal":100,"protein_g":1.5}"#)
        XCTAssertEqual(WhoopStore.decodeNutrients(json), ["energy_kcal": 100, "protein_g": 1.5])
    }

    func testPhotoIdRoundTripsAndCountsAsInUseUntilItsLastEntryGoes() async throws {
        let store = try await WhoopStore.inMemory()
        var a = entry("a"), b = entry("b", kcal: 100)
        a.photoId = "p1"; b.photoId = "p1"
        try await store.saveFoodLogEntries([a, b, entry("c")])
        let saved = try await store.foodLogEntries(from: "2026-11-08", to: "2026-11-08")
        XCTAssertEqual(saved.compactMap(\.photoId), ["p1", "p1"])
        let allIds = try await store.allFoodPhotoIds()
        XCTAssertEqual(allIds, ["p1"])
        try await store.deleteFoodLogEntries(ids: ["a"])
        let stillUsed = try await store.foodPhotoIdsInUse(["p1", "p2"])
        XCTAssertEqual(stillUsed, ["p1"])
        try await store.deleteFoodLogEntries(ids: ["b"])
        let gone = try await store.foodPhotoIdsInUse(["p1"])
        XCTAssertEqual(gone, [])
    }
}
