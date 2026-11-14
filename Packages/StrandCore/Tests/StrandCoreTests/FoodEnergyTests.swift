import XCTest
@testable import StrandCore
import WhoopStore

final class FoodEnergyTests: XCTestCase {
    private func amounts(_ values: [FoodNutrient: Double]) -> NutrientAmounts { NutrientAmounts(values) }

    // MARK: The arithmetic

    func testEnergyFollowsTheEuConversionFactors() {
        // 10 g protein, 20 g carbohydrate, 5 g fat: 40 + 80 + 45.
        let value = FoodEnergy.fromNutrients(amounts([.proteinG: 10, .carbsG: 20, .fatG: 5]))
        XCTAssertEqual(value ?? 0, 165, accuracy: 0.001)
    }

    func testFibreAndAlcoholCarryTheirOwnFactors() {
        // A label states carbohydrate without fibre, so fibre is counted beside it at 2 kcal/g, alcohol at 7.
        let withFibre = FoodEnergy.fromNutrients(amounts([.proteinG: 0, .carbsG: 0, .fatG: 0, .fiberG: 10]))
        XCTAssertEqual(withFibre ?? 0, 20, accuracy: 0.001)
        let beer = FoodEnergy.fromNutrients(amounts([.proteinG: 0.5, .carbsG: 3, .fatG: 0, .alcoholG: 4]))
        XCTAssertEqual(beer ?? 0, 2 + 12 + 28, accuracy: 0.001)
    }

    func testOneMissingMacronutrientLeavesNoEnergy() {
        XCTAssertNil(FoodEnergy.fromNutrients(amounts([.proteinG: 10, .carbsG: 20])))
        XCTAssertNil(FoodEnergy.fromNutrients(amounts([.energyKcal: 400, .sugarG: 10])))
    }

    func testContributionsLeaveOutWhatContributesNothing() {
        let split = FoodEnergy.contributions(amounts([.proteinG: 10, .carbsG: 0, .fatG: 5, .fiberG: 2]))
        XCTAssertEqual(split.map(\.nutrient), [.proteinG, .fatG, .fiberG])
        XCTAssertEqual(split.map(\.kcal), [40, 45, 4])
        XCTAssertEqual(split.reduce(0) { $0 + $1.kcal }, FoodEnergy.fromNutrients(amounts([.proteinG: 10, .carbsG: 0, .fatG: 5, .fiberG: 2])))
    }

    // MARK: Stated against computed

    func testAStatedValueThatFitsItsNutrientsDoesNotDisagree() {
        let check = FoodEnergy.check(amounts([.energyKcal: 160, .proteinG: 10, .carbsG: 20, .fatG: 5]))
        XCTAssertEqual(check?.computed ?? 0, 165, accuracy: 0.001)
        XCTAssertEqual(check?.disagrees, false)
        XCTAssertEqual(check?.isMissing, false)
    }

    func testAStatedValueFarFromItsNutrientsDisagrees() {
        let check = FoodEnergy.check(amounts([.energyKcal: 400, .proteinG: 10, .carbsG: 20, .fatG: 5]))
        XCTAssertEqual(check?.disagrees, true)
        XCTAssertEqual(check?.difference ?? 0, 235, accuracy: 0.001)
        XCTAssertEqual(check?.share ?? 0, 235 / 165, accuracy: 0.001)
    }

    func testASmallAbsoluteDifferenceIsNotCalledADisagreement() {
        // A fifth off, but 10 kcal per 100 g: rounding on a thin product says nothing.
        let check = FoodEnergy.check(amounts([.energyKcal: 50, .proteinG: 0, .carbsG: 10, .fatG: 0]))
        XCTAssertEqual(check?.share ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(check?.disagrees, false)
    }

    func testNothingStatedIsAGapNotADisagreement() {
        let check = FoodEnergy.check(amounts([.proteinG: 10, .carbsG: 20, .fatG: 5]))
        XCTAssertEqual(check?.isMissing, true)
        XCTAssertEqual(check?.disagrees, false)
        XCTAssertNil(check?.difference)
    }

    // MARK: Filling

    func testAMissingEnergyValueIsFilledAndMarked() {
        let item = FoodItem(id: "off:1", source: .online, name: "Rice cakes",
                            per100g: amounts([.proteinG: 8, .carbsG: 80, .fatG: 2]))
        let filled = FoodEnergy.filled(item)
        XCTAssertEqual(filled.per100g[.energyKcal] ?? 0, 32 + 320 + 18, accuracy: 0.001)
        XCTAssertTrue(FoodEnergy.isComputed(filled.estimatedKeys))
        XCTAssertNil(filled.estimatedFrom)      // not borrowed from a similar food, worked out from this one
    }

    func testAStatedEnergyValueIsNeverOverwritten() {
        let item = FoodItem(id: "off:2", source: .online, name: "Sugar-free sweets",
                            per100g: amounts([.energyKcal: 240, .proteinG: 0, .carbsG: 95, .fatG: 0]))
        let filled = FoodEnergy.filled(item)
        XCTAssertEqual(filled.per100g[.energyKcal] ?? 0, 240)
        XCTAssertFalse(FoodEnergy.isComputed(filled.estimatedKeys))
    }

    func testAComputedMarkSurvivesTheVitaminFilling() {
        let item = FoodEnergy.filled(FoodItem(id: "off:3", source: .online, name: "Tinned peas",
                                              per100g: amounts([.proteinG: 5, .carbsG: 10, .fatG: 0.5])))
        let reference = FoodItem(id: "bls:X1", source: .bls, name: "Peas",
                                 per100g: amounts([.proteinG: 5, .carbsG: 10, .fatG: 0.5, .ironMg: 1.5, .vitaminCMg: 20]))
        let both = FoodEstimate.filled(item, from: reference)
        XCTAssertTrue(FoodEnergy.isComputed(both.estimatedKeys))
        XCTAssertTrue(both.estimatedKeys?.contains(FoodNutrient.ironMg.rawValue) == true)
        XCTAssertEqual(both.estimatedFrom, "bls:X1")
    }

    // MARK: Restating logged entries

    private func entry(_ item: FoodItem, grams: Double) -> FoodLogEntry {
        FoodLog.entry(for: item, grams: grams, at: Date(timeIntervalSince1970: 1_700_000_000), origin: .barcode)
    }

    func testRestatingAnEntryKeepsItsAmountAndTakesTheCorrectedValues() {
        let wrong = FoodItem(id: "off:4", source: .online, name: "Oat drink",
                             per100g: amounts([.energyKcal: 450, .proteinG: 1, .carbsG: 7, .fatG: 1.5]))
        let logged = entry(wrong, grams: 200)
        let corrected = FoodItem(id: "own:1", source: .own, name: "Oat drink, barista",
                                 per100g: amounts([.energyKcal: 59, .proteinG: 1, .carbsG: 7, .fatG: 1.5]))
        let next = FoodLog.restated(logged, from: corrected)
        XCTAssertEqual(next?.grams, 200)
        XCTAssertEqual(next?.loggedAt, logged.loggedAt)
        XCTAssertEqual(next?.name, "Oat drink, barista")
        XCTAssertEqual(NutrientAmounts(stored: next?.totals ?? [:])[.energyKcal] ?? 0, 118, accuracy: 0.001)
        XCTAssertEqual(next?.foodId, logged.foodId)      // where it was logged from stays on the entry
    }

    func testRestatingWritesNothingWhenNothingChanged() {
        let item = FoodItem(id: "off:5", source: .online, name: "Butter",
                            per100g: amounts([.energyKcal: 740, .proteinG: 0.7, .carbsG: 0.6, .fatG: 82]))
        XCTAssertNil(FoodLog.restated(entry(item, grams: 10), from: item))
    }

    func testAQuickCalorieFigureHasNothingToRestate() {
        let quick = FoodLog.quickEntry(name: "Canteen", kcal: 600, at: Date(timeIntervalSince1970: 1_700_000_000))
        let item = FoodItem(id: "off:6", source: .online, name: "Canteen",
                            per100g: amounts([.energyKcal: 100, .proteinG: 1, .carbsG: 1, .fatG: 1]))
        XCTAssertNil(FoodLog.restated(quick, from: item))
    }
}
