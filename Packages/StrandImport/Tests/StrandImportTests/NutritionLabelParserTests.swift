import XCTest
@testable import StrandImport

final class NutritionLabelParserTests: XCTestCase {
    func testGermanTableReadRowByRow() {
        let reading = NutritionLabelParser.parse(lines: [
            "Nährwertangaben", "pro 100 g", "pro Portion (40 g)",
            "Energie 1799 kJ / 430 kcal 720 kJ / 172 kcal",
            "Fett 15 g 6,0 g",
            "davon gesättigte Fettsäuren 2,1 g 0,8 g",
            "Kohlenhydrate 62 g 25 g",
            "davon Zucker 18 g 7,2 g",
            "Ballaststoffe 7,5 g 3,0 g",
            "Eiweiß 9,0 g 3,6 g",
            "Salz 0,30 g 0,12 g",
        ])
        XCTAssertEqual(reading.per100["energy_kcal"], 430)
        XCTAssertEqual(reading.per100["fat_g"], 15)
        XCTAssertEqual(reading.per100["sat_fat_g"], 2.1)
        XCTAssertEqual(reading.per100["carbs_g"], 62)
        XCTAssertEqual(reading.per100["sugar_g"], 18)
        XCTAssertEqual(reading.per100["fiber_g"], 7.5)
        XCTAssertEqual(reading.per100["protein_g"], 9)
        XCTAssertEqual(reading.per100["salt_g"], 0.3)
        XCTAssertEqual(reading.per100["sodium_mg"]!, 120, accuracy: 1e-9)
        XCTAssertEqual(reading.servingAmount, 40)
        XCTAssertEqual(reading.basis, .per100g)
        XCTAssertTrue(reading.isComplete)
    }

    func testEnglishLabelWithOnlyKilojoulesAndTraces() {
        let reading = NutritionLabelParser.parse(lines: [
            "Typical values per 100ml", "Energy 180kJ", "Fat 0g", "of which saturates 0g",
            "Carbohydrate 10.6g", "of which sugars 10.6g", "Protein <0.5g", "Salt traces",
        ])
        XCTAssertEqual(reading.basis, .per100ml)
        XCTAssertEqual(reading.per100["energy_kcal"], 43)
        XCTAssertEqual(reading.per100["protein_g"], 0.5)
        XCTAssertEqual(reading.per100["salt_g"], 0)
        XCTAssertEqual(reading.per100["sat_fat_g"], 0)
        XCTAssertTrue(reading.isComplete)
    }

    func testLabelsAndNumbersReadAsTwoColumns() {
        let reading = NutritionLabelParser.parse(lines: [
            "Brennwert", "Fett", "Kohlenhydrate", "Eiweiß",
            "1569 kJ / 375 kcal", "3,1 g", "70 g", "12 g",
        ])
        XCTAssertEqual(reading.per100["energy_kcal"], 375)
        XCTAssertEqual(reading.per100["fat_g"], 3.1)
        XCTAssertEqual(reading.per100["carbs_g"], 70)
        XCTAssertEqual(reading.per100["protein_g"], 12)
    }

    func testImpossibleValuesAreDropped() {
        let reading = NutritionLabelParser.parse(lines: ["Fett 150 g", "Energie 5000 kcal", "Eiweiß 12 g"])
        XCTAssertNil(reading.per100["fat_g"])
        XCTAssertNil(reading.per100["energy_kcal"])
        XCTAssertEqual(reading.per100["protein_g"], 12)
        XCTAssertFalse(reading.isComplete)
    }
}
