import XCTest
@testable import StrandCore
import WhoopStore

final class FoodCoachReportTests: XCTestCase {
    private func entry(_ day: String, kcal: Double = 2_000, protein: Double = 120) -> FoodLogEntry {
        let totals: FoodNutrientValues = ["energy_kcal": kcal, "protein_g": protein]
        return FoodLogEntry(id: UUID().uuidString, loggedAt: Int(WeightSeries.date(forDay: day)!.timeIntervalSince1970) + 8 * 3600,
                            day: day, meal: "breakfast", foodId: "bls:G000000", name: "Gemüse", grams: 500, per100g: totals,
                            totals: totals, origin: .search, createdAt: 0, updatedAt: 0)
    }

    private let days = (0..<20).compactMap { FoodQuality.shifted("2026-11-01", by: $0, calendar: .current) }

    func testAnEmptyLogSaysSoInsteadOfLeavingTheCoachToGuess() {
        let text = FoodCoachReport.text(all: [], from: "2026-11-01", to: "2026-11-07", includeEntries: true,
                                        today: "2026-11-07", context: .init(male: true))
        XCTAssertTrue(text.contains("NO_ENTRIES"))
    }

    func testDayLinesCarryTheNoteAndTheGoal() {
        let goals = FoodGoalState.Goals(kcal: 2_000, proteinG: 150, carbCapG: nil, floorKcal: 1_500)
        let text = FoodCoachReport.text(all: days.map { entry($0) }, from: "2026-11-14", to: "2026-11-20", includeEntries: true,
                                        today: "2026-11-21", context: .init(male: true, goals: { _ in goals }))
        XCTAssertTrue(text.contains("2026-11-20: · kcal 2000 · protein 120 g"))
        XCTAssertTrue(text.contains("goal 2000 kcal: inRange, protein under goal"))
        XCTAssertTrue(text.contains("note "))
        XCTAssertTrue(text.contains("ENTRIES:"))
        XCTAssertTrue(text.contains("NOTE_7_DAYS ending 2026-11-20"))
        XCTAssertTrue(text.contains("STREAK: 20 days"))
    }

    func testLongSpansListDayLinesButNoEntries() {
        let text = FoodCoachReport.text(all: days.map { entry($0) }, from: "2026-11-01", to: "2026-11-20", includeEntries: true,
                                        today: "2026-11-21", context: .init(male: true))
        XCTAssertTrue(text.contains("ENTRIES: not listed, the span has 20 logged days"))
        XCTAssertTrue(text.contains("2026-11-01:"))
    }
}
