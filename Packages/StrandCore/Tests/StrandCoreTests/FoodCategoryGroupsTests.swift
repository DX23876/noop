import XCTest
@testable import StrandCore

/// Category IDs as Open Food Facts returns them, ancestors included (taken from the taxonomy of 2026-11-25).
final class FoodCategoryGroupsTests: XCTestCase {
    private let rolledOats = ["en:plant-based-foods-and-beverages", "en:plant-based-foods", "en:breakfasts",
                              "en:cereals-and-potatoes", "en:cereals-and-their-products", "en:breakfast-cereals",
                              "en:flakes", "en:cereal-flakes", "en:rolled-flakes", "en:oats-and-their-products",
                              "en:rolled-oats"]
    private let oatDrink = ["en:beverages", "en:plant-based-beverages", "en:cereal-based-drinks",
                            "en:cereals-and-their-products", "en:dairy-substitutes", "en:milk-substitutes",
                            "en:oats-and-their-products", "en:oat-based-drinks"]

    func testOatFlakesAreWholeGrainWhateverTheirName() {
        XCTAssertEqual(FoodCategoryGroups.group(for: rolledOats), "whole-grain")
        for name in ["haferflocken", "flocons d'avoine", "copos de avena", "oats"] {
            XCTAssertTrue(FoodScore.isWholeGrain(group: FoodCategoryGroups.group(for: rolledOats), name: name), name)
        }
    }

    func testAnOatDrinkIsADrinkAndNotTheGrain() {
        XCTAssertEqual(FoodCategoryGroups.group(for: oatDrink), "beverages")
    }

    func testWholemealBreadAndWholeWheatPastaButNotSemiWhole() {
        XCTAssertEqual(FoodCategoryGroups.group(for: ["en:cereals-and-their-products", "en:breads", "en:wholemeal-breads"]),
                       "whole-grain")
        XCTAssertEqual(FoodCategoryGroups.group(for: ["en:pastas", "en:noodles", "en:whole-wheat-noodles"]), "whole-grain")
        XCTAssertNil(FoodCategoryGroups.group(for: ["en:pastas", "en:whole-or-semi-whole-durum-wheat-pasta"]),
                     "semi-whole may be half refined")
        XCTAssertNil(FoodCategoryGroups.group(for: ["en:dairies", "en:whole-milk-yogurts"]), "whole milk is no grain")
    }

    func testPulsesNutsAndSeedsAreToldApart() {
        XCTAssertEqual(FoodCategoryGroups.group(for: ["en:legumes", "en:pulses", "en:seeds", "en:chickpeas"]), "legumes")
        XCTAssertEqual(FoodCategoryGroups.group(for: ["en:nuts", "en:walnuts"]), "nuts")
        XCTAssertEqual(FoodCategoryGroups.group(for: ["en:plant-based-foods", "en:seeds", "en:chia"]), "nuts")
        XCTAssertEqual(FoodCategoryGroups.group(for: ["en:cereals-and-their-products", "en:rices", "en:seeds", "en:brown-rices"]),
                       "whole-grain", "brown rice sits under seeds in the taxonomy and is a grain")
    }

    func testAGranolaCarriesBothItsGrainAndItsNuts() {
        let group = FoodCategoryGroups.group(for: rolledOats + ["en:nuts"])
        XCTAssertEqual(group, "whole-grain,nuts")
    }

    func testJuiceAndColaAreDrinks() {
        XCTAssertEqual(FoodCategoryGroups.group(for: ["en:beverages", "en:fruit-juices", "en:fruits-based-foods"]),
                       "fruit-juices-beverage")
        XCTAssertEqual(FoodCategoryGroups.group(for: ["en:beverages", "en:sodas", "en:colas"]), "beverages")
    }

    func testNothingKnownLeavesTheGroupAlone() {
        XCTAssertNil(FoodCategoryGroups.group(for: []))
        XCTAssertNil(FoodCategoryGroups.group(for: ["en:sweet-spreads"]))
    }

    func testOnlineResultsTakeTheCategoryGroup() {
        let json: [String: Any] = ["code": "4000000000001", "product_name": "Haferflocken",
                                   "pnns_groups_2": "Breakfast cereals", "categories_tags": rolledOats,
                                   "nutriments": ["energy-kcal_100g": 372, "proteins_100g": 13.5,
                                                  "carbohydrates_100g": 58.7, "fat_100g": 7.0]]
        XCTAssertEqual(FoodOnline.product(json, language: "de")?.group, "whole-grain")
    }
}
