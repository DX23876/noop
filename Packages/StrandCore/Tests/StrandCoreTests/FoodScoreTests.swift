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
        XCTAssertEqual(FoodScore.upTo(5, full: 5), 1)
        XCTAssertEqual(FoodScore.upTo(2.5, full: 5), 0.5)
        XCTAssertEqual(FoodScore.upTo(9, full: 5), 1)
        XCTAssertEqual(FoodScore.ramp(0, from: 0, to: 1), 0)
        XCTAssertEqual(FoodScore.ramp(0.5, from: 0, to: 1), 0.5)
        XCTAssertEqual(FoodScore.ramp(2, from: 0, to: 1), 1)
        XCTAssertEqual(FoodScore.ramp(4, from: 5, to: 10), 0)
    }

    /// Salt keeps falling past its first threshold: a day at three times the limit cannot read like a day at it.
    func testSaltCostsHalfAtItsFirstThresholdAndAllAtItsLast() {
        XCTAssertEqual(FoodScore.sodiumCost(1_500), 0)
        XCTAssertEqual(FoodScore.sodiumCost(1_900), 0.25, accuracy: 0.001)
        XCTAssertEqual(FoodScore.sodiumCost(2_300), 0.5, accuracy: 0.001)
        XCTAssertEqual(FoodScore.sodiumCost(3_150), 0.75, accuracy: 0.001)
        XCTAssertEqual(FoodScore.sodiumCost(4_000), 1, accuracy: 0.001)
        XCTAssertEqual(FoodScore.sodiumCost(12_800), 1, accuracy: 0.001)
    }

    func testSweatAllowanceShiftsEverySaltThreshold() {
        XCTAssertEqual(FoodScore.sodiumCost(2_000, allowanceMg: 500), 0)
        XCTAssertEqual(FoodScore.sodiumCost(2_800, allowanceMg: 500), 0.5, accuracy: 0.001)
        XCTAssertEqual(FoodScore.sodiumCost(4_500, allowanceMg: 500), 1, accuracy: 0.001)
    }

    /// The allowance comes from the burn above the usual day, never from the diet plan's active-day bonus, which
    /// is zero unless the wearer switched active days on (owner, 2026-11-22).
    func testSweatAllowanceFollowsTheExtraBurn() {
        XCTAssertEqual(FoodSweat.allowanceMg(burnedKcal: 2_400, usualBurnKcal: 2_400), 0)
        XCTAssertEqual(FoodSweat.allowanceMg(burnedKcal: 2_600, usualBurnKcal: 2_400), 300)
        XCTAssertEqual(FoodSweat.allowanceMg(burnedKcal: 3_000, usualBurnKcal: 2_400), FoodSweat.maximumMg)
        XCTAssertEqual(FoodSweat.allowanceMg(burnedKcal: 5_000, usualBurnKcal: 2_400), FoodSweat.maximumMg)
        // Half way through today, the usual day counts half too.
        XCTAssertEqual(FoodSweat.allowanceMg(burnedKcal: 1_400, usualBurnKcal: 2_400, elapsedFraction: 0.5), 300)
        XCTAssertEqual(FoodSweat.allowanceMg(burnedKcal: nil, usualBurnKcal: 2_400), 0)
        XCTAssertEqual(FoodSweat.allowanceMg(burnedKcal: 3_000, usualBurnKcal: 0), 0)
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

    /// The point of the new shape: a food the log cannot place earns nothing and costs nothing, so the score of a
    /// day that is all unknown food is exactly a neutral day (owner, 2026-11-22).
    func testUnplacedFoodNeitherEarnsNorCosts() throws {
        let entries = days.map { entry("own:1", "Irgendwas", day: $0, grams: 400, totals: ["energy_kcal": 2_000]) }
        let result = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", male: true))
        XCTAssertEqual(result.score, FoodScore.base, accuracy: 0.001)
        XCTAssertTrue(result.parts.allSatisfy { abs($0.points) < 0.001 })
    }

    func testVegetablesFruitAndJuiceAreTold() throws {
        // Per day: 400 g vegetables (5 portions), 160 g fruit (2 portions), 250 ml juice with 22 g sugar.
        let entries = days.flatMap { day in [
            entry("bls:G100000", "Brokkoli gegart", day: day, grams: 400, totals: ["energy_kcal": 100]),
            entry("bls:F100000", "Apfel roh", day: day, grams: 160, totals: ["energy_kcal": 100]),
            entry("bls:F600000", "Orangensaft", day: day, grams: 250,
                  totals: ["energy_kcal": 1_800, "sugar_g": 22.5], per100g: ["energy_kcal": 45, "sugar_g": 9]),
        ] }
        let result = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", male: false))
        XCTAssertEqual(part(result, .vegetables).points, 10)
        XCTAssertEqual(part(result, .vegetables).amountPerDay, 5, accuracy: 0.001)
        XCTAssertEqual(part(result, .fruit).points, 5, accuracy: 0.001)
        // Juice is a drink, not fruit, and its sugar is free sugar: 22.5 g on 2,000 kcal is 4.5 % of the energy,
        // just under the WHO's ideal, so it costs nothing yet.
        XCTAssertEqual(part(result, .freeSugar).amountPerDay, 4.5, accuracy: 0.01)
        XCTAssertEqual(part(result, .freeSugar).points, 0, accuracy: 0.001)
    }

    /// Mushrooms count with the vegetables; potatoes do not count as vegetables at all.
    func testMushroomsCountAsVegetablesAndPotatoesDoNot() throws {
        let entries = days.flatMap { day in [
            entry("bls:K701100", "Champignon roh", day: day, grams: 160),
            entry("bls:D100000", "Kartoffel gekocht", day: day, grams: 300),
        ] }
        let result = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", male: true))
        XCTAssertEqual(part(result, .vegetables).amountPerDay, 2, accuracy: 0.001)
    }

    func testRedAndProcessedMeatAreSeparateParts() throws {
        let entries = days.flatMap { day in [
            entry("bls:U100000", "Rind Hackfleisch", day: day, grams: 85),
            entry("bls:W100000", "Salami", day: day, grams: 42.5),
            entry("bls:U200000", "Hähnchenbrust", day: day, grams: 200),
        ] }
        let result = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", male: true))
        // Red meat: free up to 350 g a week (50 g a day), spent at 1,000 g a week, and worth half a part.
        XCTAssertEqual(part(result, .redMeat).amountPerDay, 85, accuracy: 0.001)
        XCTAssertEqual(part(result, .redMeat).points,
                       -5 * (85 - 1_000.0 / 7 * 0.35) / (1_000.0 / 7 - 1_000.0 / 7 * 0.35), accuracy: 0.01)
        // Processed meat: half a portion a day of the 1.5 portions that spend the whole part.
        XCTAssertEqual(part(result, .processedMeat).amountPerDay, 0.5, accuracy: 0.001)
        XCTAssertEqual(part(result, .processedMeat).points, -10.0 / 3, accuracy: 0.01)
        // Poultry is neither.
        XCTAssertGreaterThan(part(result, .redMeat).points, -5)
    }

    func testFreeSugarAndSaturatedFatRunOnTheirWhoThresholds() throws {
        let entries = days.map { day in
            entry("own:1", "Müsliriegel", day: day, grams: 100, totals: [
                "energy_kcal": 2_000, "sugar_g": 50, "sat_fat_g": 2_000 * 0.2 / 9,
            ])
        }
        let facts = ["own:1": FoodScore.FoodFacts(freeSugarShare: 0.5)]
        let result = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", facts: facts, male: true))
        // Half of 50 g is free sugar: 25 g is 5 % of 2,000 kcal, the WHO's ideal, so nothing is off yet.
        XCTAssertEqual(part(result, .freeSugar).amountPerDay, 5, accuracy: 0.001)
        XCTAssertEqual(part(result, .freeSugar).points, 0, accuracy: 0.001)
        // Saturated fat at a fifth of the energy is half way from the WHO's 10 % to the 30 % that spends the part.
        XCTAssertEqual(part(result, .satFat).amountPerDay, 20, accuracy: 0.001)
        XCTAssertEqual(part(result, .satFat).points, -5, accuracy: 0.001)
    }

    func testSaltStandsInForMissingSodiumAndAlcoholLowersTheScore() throws {
        let sober = days.map { entry("bls:X100000", "Gericht", day: $0, totals: ["energy_kcal": 2_000, "salt_g": 3.75]) }
        let drinking = days.map { entry("bls:X100000", "Gericht", day: $0, totals: ["energy_kcal": 2_000, "salt_g": 3.75, "alcohol_g": 28]) }
        let a = try XCTUnwrap(FoodScore.week(entries: sober, lastDay: "2026-11-08", male: false))
        let b = try XCTUnwrap(FoodScore.week(entries: drinking, lastDay: "2026-11-08", male: false))
        XCTAssertEqual(part(a, .sodium).points, 0, accuracy: 0.001)                 // 3.75 g salt = 1,500 mg sodium
        XCTAssertEqual(part(b, .alcohol).points, -10 * 2 / 2.5, accuracy: 0.001)   // two drinks of a 2.5 limit
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
        // Every part but one: whole grains or, for keto and low carb, fibre in their place.
        XCTAssertEqual(result.parts.count, FoodScore.Component.allCases.count - 1)
    }

    // MARK: Classification

    /// A granola is part cereal and part seeds, and the score counts both from one classification.
    func testClassificationSplitsAFoodOverSeveralGroups() throws {
        let entries = days.map { entry("own:granola", "Kerne & Saaten Granola", day: $0, grams: 75,
                                       totals: ["energy_kcal": 433]) }
        let facts = ["own:granola": FoodClassification(shares: [.nuts: 0.35], wholeGrainShare: 0.4)
            .facts(group: "breakfast-cereals", nova: 3)]
        let result = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", facts: facts, male: true))
        XCTAssertEqual(part(result, .nutsLegumes).amountPerDay, 75 * 0.35 / 28, accuracy: 0.001)
        XCTAssertEqual(part(result, .wholeGrains).amountPerDay, 30, accuracy: 0.001)
        XCTAssertEqual(part(result, .wholeGrains).points, 10 * 30 / 90, accuracy: 0.001)
    }

    /// Oats are whole grain whatever the packet calls them; the name alone never knew that.
    func testWholeGrainComesFromTheClassificationNotTheName() throws {
        let entries = days.map { entry("own:oats", "Zarte Hafer Flocken", day: $0, grams: 90, totals: ["energy_kcal": 335]) }
        let bare = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", male: true))
        XCTAssertEqual(part(bare, .wholeGrains).points, 0)
        let facts = ["own:oats": FoodClassification(wholeGrainShare: 1).facts(group: nil, nova: 1)]
        let classified = try XCTUnwrap(FoodScore.week(entries: entries, lastDay: "2026-11-08", facts: facts, male: true))
        XCTAssertEqual(part(classified, .wholeGrains).points, 10, accuracy: 0.001)
    }

    func testClassificationRefusesMoreThanAWholeFood() {
        XCTAssertTrue(FoodClassification(shares: [.nuts: 0.35, .vegetables: 0.2], wholeGrainShare: 0.4).isSound)
        XCTAssertFalse(FoodClassification(shares: [.nuts: 0.7, .vegetables: 0.7]).isSound)
        XCTAssertFalse(FoodClassification(shares: [.nuts: -0.1]).isSound)
        XCTAssertFalse(FoodClassification(wholeGrainShare: 1.5).isSound)
        XCTAssertFalse(FoodClassification(freeSugarShare: .nan).isSound)
        // An empty classification is an answer: this food is none of the groups the score counts.
        XCTAssertTrue(FoodClassification().isSound)
    }

    func testClassificationSurvivesItsJson() throws {
        let value = FoodClassification(shares: [.nuts: 0.35, .vegetables: 0.1], wholeGrainShare: 0.4,
                                       freeSugarShare: 0.8, author: .wearer)
        let back = try XCTUnwrap(FoodClassification.decode(try XCTUnwrap(value.json)))
        XCTAssertEqual(back, value)
        XCTAssertEqual(back.groupShares[.nuts], 0.35)
        XCTAssertEqual(back.author, .wearer)
        XCTAssertNil(FoodClassification.decode("not json"))
        XCTAssertNil(FoodClassification.decode(nil))
    }

    /// The wearer's own answer stands above the coach's and is never replaced by it.
    func testTheWearersClassificationIsNotOverwritten() throws {
        let wearer = FoodClassification(shares: [.vegetables: 1], author: .wearer)
        let coach = FoodClassification(shares: [.fruit: 1], author: .coach)
        XCTAssertEqual(FoodLibrary.keptClassification(coach, stored: wearer.json)?.groupShares, [.vegetables: 1])
        XCTAssertEqual(FoodLibrary.keptClassification(wearer, stored: coach.json)?.groupShares, [.vegetables: 1])
        XCTAssertEqual(FoodLibrary.keptClassification(nil, stored: coach.json)?.groupShares, [.fruit: 1])
        XCTAssertNil(FoodLibrary.keptClassification(nil, stored: nil))
    }

    func testABetterWeekScoresHigher() throws {
        let poor = days.flatMap { day in [
            entry("bls:W100000", "Salami", day: day, grams: 170,
                  totals: ["energy_kcal": 600, "sodium_mg": 4_000, "sat_fat_g": 30]),
            entry("bls:N100000", "Cola", day: day, grams: 500,
                  totals: ["energy_kcal": 210, "sugar_g": 53], per100g: ["energy_kcal": 42, "sugar_g": 10.6]),
        ] }
        let good = days.flatMap { day in [
            entry("bls:G100000", "Brokkoli", day: day, grams: 400),
            entry("bls:F100000", "Apfel", day: day, grams: 320),
            entry("bls:H100000", "Linsen gekocht", day: day, grams: 80),
            entry("bls:T100000", "Lachs", day: day, grams: 100,
                  totals: ["energy_kcal": 200, "epa_g": 0.5, "dha_g": 1.2, "sodium_mg": 60]),
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
