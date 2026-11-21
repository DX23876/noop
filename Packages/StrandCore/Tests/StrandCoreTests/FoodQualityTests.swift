import XCTest
@testable import StrandCore
import WhoopStore

final class FoodQualityTests: XCTestCase {
    private func entry(_ foodId: String?, _ name: String, day: String, grams: Double = 100, kcal: Double = 100,
                       extra: FoodNutrientValues = [:]) -> FoodLogEntry {
        var totals: FoodNutrientValues = ["energy_kcal": kcal]
        for (key, value) in extra { totals[key] = value }
        return FoodLogEntry(id: UUID().uuidString, loggedAt: 0, day: day, foodId: foodId, name: name, grams: grams,
                            per100g: totals, totals: totals, origin: .search, createdAt: 0, updatedAt: 0)
    }

    private let week = ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"]

    private func part(_ note: FoodQuality.Note, _ c: FoodScore.Component) -> FoodScore.Part? {
        note.parts.first { $0.component == c }
    }

    private func note(_ result: Result<FoodQuality.Note, FoodQuality.MissingError>) throws -> FoodQuality.Note {
        try result.get()
    }

    func testADayWithoutFishBorrowsTheWeeksFish() throws {
        // Salmon on Monday only; the Sunday note still sees the week's omega-3.
        var entries = week.map { entry("bls:G000000", "Brokkoli", day: $0, grams: 400, kcal: 1_500) }
        entries.append(entry("bls:T000000", "Lachs", day: week[0], grams: 150, kcal: 300, extra: ["epa_g": 1, "dha_g": 1.5]))
        let sunday = try note(FoodQuality.day(week[6], entries: entries, male: true, usualKcal: nil, today: "2026-11-30"))
        // 2,500 mg over 7 logged days is about 357 mg a day: full points, though Sunday itself had no fish.
        XCTAssertEqual(try XCTUnwrap(part(sunday, .fishOmega3)).points, 10, accuracy: 0.001)
        XCTAssertFalse(sunday.provisional)
        XCTAssertEqual(sunday.span, 1)
    }

    func testASteakWeighsOnTheWholeWeek() throws {
        var entries = week.map { entry("bls:G000000", "Brokkoli", day: $0, grams: 400, kcal: 1_500) }
        entries.append(entry("bls:U100000", "Rind Steak", day: week[0], grams: 700, kcal: 1_000))
        let sunday = try note(FoodQuality.day(week[6], entries: entries, male: true, usualKcal: nil, today: "2026-11-30"))
        // 700 g in the week is 100 g a day: past the 50 g free allowance.
        XCTAssertLessThan(try XCTUnwrap(part(sunday, .redMeat)).points, 10)
        let laterWeek = try note(FoodQuality.day("2026-11-09", entries: entries + [entry("bls:G000000", "Brokkoli", day: "2026-11-09", grams: 400, kcal: 1_500)],
                                                 male: true, usualKcal: nil, today: "2026-11-30"))
        XCTAssertEqual(try XCTUnwrap(part(laterWeek, .redMeat)).points, 10, accuracy: 0.001, "seven days on, the steak is out of the window")
    }

    func testSausageIsStrictAndRedMeatIsFreeUpToTheWcrfLimit() throws {
        let sausage = week.map { entry("bls:W100000", "Salami", day: $0, grams: 85) }
        let beef = week.map { entry("bls:U100000", "Rind", day: $0, grams: 50) }
        let s = try XCTUnwrap(FoodQuality.period(span: 7, lastDay: week[6], entries: sausage, male: true, today: "2026-11-30"))
        let b = try XCTUnwrap(FoodQuality.period(span: 7, lastDay: week[6], entries: beef, male: true, today: "2026-11-30"))
        XCTAssertEqual(try XCTUnwrap(part(s, .redMeat)).points, 10 * 0.5 / 1.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(part(b, .redMeat)).points, 10, accuracy: 0.001)
    }

    func testKetoScoresFibreInPlaceOfWholeGrains() throws {
        let entries = week.map { entry("bls:G000000", "Brokkoli", day: $0, grams: 300, kcal: 1_500, extra: ["fiber_g": 30]) }
        let keto = try XCTUnwrap(FoodQuality.period(span: 7, lastDay: week[6], entries: entries, male: true,
                                                    options: .forDiet(.keto), today: "2026-11-30"))
        XCTAssertNil(part(keto, .wholeGrains))
        XCTAssertEqual(try XCTUnwrap(part(keto, .fiber)).points, 10, accuracy: 0.001)
        let plain = try XCTUnwrap(FoodQuality.period(span: 7, lastDay: week[6], entries: entries, male: true, today: "2026-11-30"))
        XCTAssertEqual(try XCTUnwrap(part(plain, .wholeGrains)).points, 0, accuracy: 0.001)
        XCTAssertGreaterThan(keto.score, plain.score)
    }

    func testAPeriodAddsAmountsUpBeforeScoring() throws {
        // 10 portions one day, none the next: the pooled week reads 5 a day, full points; averaging day notes
        // would give only half, since a day is capped at 10.
        let entries = [entry("bls:G000000", "Brokkoli", day: week[5], grams: 800, kcal: 1_500),
                       entry("bls:B000000", "Brot", day: week[6], grams: 100, kcal: 1_500)]
        let pooled = FoodQuality.period(span: 7, lastDay: week[6], entries: entries, male: true, today: "2026-11-30")
        XCTAssertNil(pooled, "two logged days are too few for a week")
        let many = week.enumerated().map { i, day in
            entry("bls:G000000", "Brokkoli", day: day, grams: i.isMultiple(of: 2) ? 800 : 0.001, kcal: 1_500)
        }
        let note = try XCTUnwrap(FoodQuality.period(span: 7, lastDay: week[6], entries: many, male: true, today: "2026-11-30"))
        XCTAssertEqual(try XCTUnwrap(part(note, .vegetables)).amountPerDay, 3_200.0 / 80 / 7, accuracy: 0.01)
    }

    func testAHalfLoggedDayHasNoNoteYet() {
        let entries = [entry("bls:G000000", "Brokkoli", day: week[6], grams: 200, kcal: 600)]
        let result = FoodQuality.day(week[6], entries: entries, male: true, usualKcal: 2_000, today: week[6])
        XCTAssertEqual(result.failureReason, .tooLittle(loggedKcal: 600, neededKcal: 1_000))
        let enough = entries + [entry("bls:B000000", "Brot", day: week[6], grams: 200, kcal: 500)]
        let today = try? FoodQuality.day(week[6], entries: enough, male: true, usualKcal: 2_000, today: week[6]).get()
        XCTAssertEqual(today?.provisional, true)
        XCTAssertEqual(FoodQuality.day(week[5], entries: enough, male: true, usualKcal: 2_000, today: week[6]).failureReason, .nothing)
    }

    func testTheUsualIntakeIsTheMedianOfTheLoggedDaysBefore() {
        let entries = [entry(nil, "a", day: week[0], kcal: 1_800), entry(nil, "b", day: week[1], kcal: 2_400),
                       entry(nil, "c", day: week[2], kcal: 2_000), entry(nil, "d", day: week[3], kcal: 9_000)]
        XCTAssertEqual(FoodQuality.usualKcal(entries: entries, before: week[3]), 2_000)
        XCTAssertNil(FoodQuality.usualKcal(entries: entries, before: week[2]), "two days are too few")
    }

    func testUnplacedFoodMakesTheNoteUncertainFromThirtyPercent() throws {
        let placed = entry("bls:G000000", "Brokkoli", day: week[6], kcal: 650)
        let quick = FoodLog.quickEntry(name: "Kantine", kcal: 350, at: WeightSeries.date(forDay: week[6])!)
        let sure = try note(FoodQuality.day(week[6], entries: [placed, entry(nil, "x", day: week[6], kcal: 250)],
                                            male: true, usualKcal: nil, today: "2026-11-30"))
        XCTAssertFalse(sure.uncertain)
        let unsure = try note(FoodQuality.day(week[6], entries: [placed, quick], male: true, usualKcal: nil, today: "2026-11-30"))
        XCTAssertEqual(unsure.placedShare, 0.65, accuracy: 0.001)
        XCTAssertTrue(unsure.uncertain)
        // An own food with a stored group is placed.
        let own = entry("own:1", "Müsli", day: week[6], kcal: 350)
        let withGroup = try note(FoodQuality.day(week[6], entries: [placed, own], facts: ["own:1": .init(group: "cereals")],
                                                 male: true, usualKcal: nil, today: "2026-11-30"))
        XCTAssertEqual(withGroup.placedShare, 1, accuracy: 0.001)
    }
}

private extension Result where Failure == FoodQuality.MissingError {
    var failureReason: FoodQuality.Missing? {
        if case .failure(let error) = self { return error.reason }
        return nil
    }
}
