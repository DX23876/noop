import XCTest
@testable import StrandCore
import WhoopStore

final class FoodScoreTests: XCTestCase {
    private func entry(_ foodId: String?, _ name: String, day: String, grams: Double = 100,
                       totals: FoodNutrientValues = ["energy_kcal": 100], per100g: FoodNutrientValues? = nil) -> FoodLogEntry {
        FoodLogEntry(id: UUID().uuidString, loggedAt: 0, day: day, foodId: foodId, name: name, grams: grams,
                     per100g: per100g ?? totals, totals: totals, origin: .search, createdAt: 0, updatedAt: 0)
    }

    private let days = ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"]

    private func part(_ result: FoodScore.Result, _ c: FoodScore.Component) -> FoodScore.Part {
        result.parts.first { $0.component == c }!
    }

    // MARK: Point curves

    func testCurvesHitTheirEnds() {
        XCTAssertEqual(FoodScore.more(5, full: 5), 10)
        XCTAssertEqual(FoodScore.more(2.5, full: 5), 5)
        XCTAssertEqual(FoodScore.more(9, full: 5), 10)
        XCTAssertEqual(FoodScore.less(0, best: 0, worst: 1), 10)
        XCTAssertEqual(FoodScore.less(0.5, best: 0, worst: 1), 5)
        XCTAssertEqual(FoodScore.less(2, best: 0, worst: 1), 0)
        XCTAssertEqual(FoodScore.less(1_500, best: 1_500, worst: 4_000), 10)
        XCTAssertEqual(FoodScore.less(2_750, best: 1_500, worst: 4_000), 5)
        XCTAssertEqual(FoodScore.less(4_000, best: 1_500, worst: 4_000), 0)
        XCTAssertEqual(FoodScore.between(2, zeroAt: 2, fullAt: 10), 0)
        XCTAssertEqual(FoodScore.between(6, zeroAt: 2, fullAt: 10), 5)
        XCTAssertEqual(FoodScore.between(12, zeroAt: 2, fullAt: 10), 10)
    }

    // MARK: Week

    func testNoScoreBelowFiveLoggedDays() {
        let four = days.prefix(4).map { entry("bls:G100000", "Brokkoli", day: $0) }
        XCTAssertNil(FoodScore.week(entries: four, lastDay: "2026-11-08", male: true))
        let five = days.prefix(5).map { entry("bls:G100000", "Brokkoli", day: $0) }
        XCTAssertEqual(FoodScore.week(entries: five, lastDay: "2026-11-08", male: true)?.loggedDays, 5)
    }

    func testDaysOutsideTheWeekDoNotCount() {
        let old = ["2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24"].map { entry("bls:G100000", "Brokkoli", day: $0) }
        XCTAssertNil(FoodScore.week(entries: old, lastDay: "2026-11-08", male: nil))
    }

    func testVegetablesFruitAndJuiceAreTold() throws {
        // Per day: 400 g vegetables (5 portions), 160 g fruit (2 portions), 250 ml sweet juice (1 portion).
        let entries = days.flatMap { day in [
            entry("bls:G100000", "Brokkoli gegart", day: day, grams: 400),
            entry("bls:K100000", "Kartoffel gekocht", day: day, grams: 300),   // potatoes are not vegetables
            entry("bls:F100000", "Apfel roh", day: day, grams: 160),
            entry("bls:F600000", "Orangensaft", day: day, grams: 250, per100g: ["energy_kcal": 45, "sugar_g": 9]),
        ] }
        let result = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", male: false))
        XCTAssertEqual(part(result, .vegetables).points, 10)
        XCTAssertEqual(part(result, .vegetables).amountPerDay, 5, accuracy: 0.001)
        XCTAssertEqual(part(result, .fruit).points, 5, accuracy: 0.001)
        XCTAssertEqual(part(result, .sugaryDrinks).points, 0, accuracy: 0.001)
    }

    func testRedMeatCountsButPoultryDoesNot() throws {
        let entries = days.flatMap { day in [
            entry("bls:U100000", "Rind Hackfleisch", day: day, grams: 85),
            entry("bls:U200000", "Hähnchenbrust", day: day, grams: 200),
        ] }
        let result = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", male: true))
        XCTAssertEqual(part(result, .redMeat).amountPerDay, 1, accuracy: 0.001)
        XCTAssertEqual(part(result, .redMeat).points, 10 * 0.5 / 1.5, accuracy: 0.001)
    }

    func testNutrientsAlcoholAndSodiumOnFixedLimits() throws {
        let entries = days.map { day in
            entry("bls:X100000", "Gericht", day: day, grams: 500, totals: [
                "energy_kcal": 2_000, "poly_fat_g": 2_000 * 0.06 / 9, "epa_g": 0.1, "dha_g": 0.025,
                "sodium_mg": 2_750, "alcohol_g": 0,
            ])
        }
        let result = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", male: true))
        XCTAssertEqual(part(result, .polyFats).points, 5, accuracy: 0.001)
        XCTAssertEqual(part(result, .fishOmega3).points, 5, accuracy: 0.001)
        XCTAssertEqual(part(result, .sodium).points, 5, accuracy: 0.001)
        XCTAssertEqual(part(result, .alcohol).points, 10)
    }

    func testSaltStandsInForMissingSodiumAndAlcoholLowersTheScore() throws {
        let sober = days.map { entry("bls:X100000", "Gericht", day: $0, totals: ["energy_kcal": 2_000, "salt_g": 3.75]) }
        let drinking = days.map { entry("bls:X100000", "Gericht", day: $0, totals: ["energy_kcal": 2_000, "salt_g": 3.75, "alcohol_g": 28]) }
        let a = try XCTUnwrap(FoodScore.week(entries: sober, lastDay: "2026-11-08", male: false))
        let b = try XCTUnwrap(FoodScore.week(entries: drinking, lastDay: "2026-11-08", male: false))
        XCTAssertEqual(part(a, .sodium).points, 10, accuracy: 0.001)               // 3.75 g salt = 1,500 mg sodium
        XCTAssertEqual(part(b, .alcohol).points, 10 * 0.5 / 2.5, accuracy: 0.001)  // two drinks of a 2.5 limit
        XCTAssertLessThan(b.score, a.score)
    }

    func testProductsUseTheirStoredGroupAndProcessedShareStaysOutside() throws {
        let entries = days.flatMap { day in [
            entry("off:1", "Gemüsemischung", day: day, grams: 160, totals: ["energy_kcal": 100]),
            entry("off:2", "Chips", day: day, grams: 50, totals: ["energy_kcal": 300]),
        ] }
        let facts = ["off:1": FoodScore.FoodFacts(group: "vegetables", nova: 1),
                     "off:2": FoodScore.FoodFacts(group: "appetizers", nova: 4)]
        let result = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", facts: facts, male: nil))
        XCTAssertEqual(part(result, .vegetables).amountPerDay, 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.processedShare), 0.75, accuracy: 0.001)
        XCTAssertEqual(result.parts.count, FoodScore.Component.allCases.count)
    }

    func testABetterWeekScoresHigher() throws {
        let poor = days.flatMap { day in [
            entry("bls:W100000", "Salami", day: day, grams: 170, totals: ["energy_kcal": 600, "sodium_mg": 4_000]),
            entry("bls:N100000", "Cola", day: day, grams: 500, per100g: ["energy_kcal": 42, "sugar_g": 10.6]),
        ] }
        let good = days.flatMap { day in [
            entry("bls:G100000", "Brokkoli", day: day, grams: 400),
            entry("bls:F100000", "Apfel", day: day, grams: 320),
            entry("bls:H100000", "Linsen gekocht", day: day, grams: 80),
            entry("bls:T100000", "Lachs", day: day, grams: 100, totals: ["energy_kcal": 200, "epa_g": 0.5, "dha_g": 1.2, "sodium_mg": 60]),
        ] }
        let p = try XCTUnwrap(FoodScore.week(entries: poor, lastDay: "2026-11-08", male: true))
        let g = try XCTUnwrap(FoodScore.week(entries: good, lastDay: "2026-11-08", male: true))
        XCTAssertGreaterThan(g.score, p.score + 30)
        XCTAssertLessThanOrEqual(g.score, 100)
        XCTAssertGreaterThanOrEqual(p.score, 0)
    }

    // MARK: Evening sentence

    func testSentenceNamesTheBestThingAndOneToWatch() {
        let refs: [FoodNutrient: FoodReference.Value] = [
            .fiberG: .init(amount: 30, kind: .atLeast, source: "x"),
            .saltG: .init(amount: 6, kind: .atMost, source: "x"),
        ]
        let day = NutrientAmounts([.energyKcal: 2_000, .proteinG: 150, .fiberG: 12, .saltG: 9])
        let points = FoodDaySentence.points(totals: day, proteinGoalG: 140, references: refs)
        XCTAssertEqual(points.map(\.nutrient), [.proteinG, .fiberG])
        XCTAssertEqual(points.map(\.watch), [false, true])
        XCTAssertTrue(FoodDaySentence.points(totals: NutrientAmounts([.energyKcal: 300, .proteinG: 200]),
                                             proteinGoalG: 140, references: refs).isEmpty)
    }
}
