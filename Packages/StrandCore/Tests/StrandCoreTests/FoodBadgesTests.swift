import XCTest
@testable import StrandCore
import WhoopStore

final class FoodBadgesTests: XCTestCase {
    private let calendar = FoodBadges.isoCalendar

    private func days(from first: String, count: Int) -> [String] {
        (0..<count).compactMap { FoodQuality.shifted(first, by: $0, calendar: calendar) }
    }

    private func note(_ sunday: String, score: Double, parts: [FoodScore.Part] = [], placed: Double = 1) -> FoodQuality.Note {
        FoodQuality.Note(day: sunday, span: 7, score: score, parts: parts, loggedDays: 7, placedShare: placed,
                         processedShare: nil, provisional: false)
    }

    func testTheStreakBridgesOneMissedDayAWeek() {
        // Monday 2026-11-02 to Sunday 2026-11-15, Wednesday the 11th missed.
        var logged = Set(days(from: "2026-11-02", count: 14))
        logged.remove("2026-11-11")
        XCTAssertEqual(FoodBadges.streak(days: logged, today: "2026-11-15", calendar: calendar), 13)
        // A second miss in the same week ends the run there: the 13th takes the joker, the 11th ends it
        // (15th, 14th, 12th).
        logged.remove("2026-11-13")
        XCTAssertEqual(FoodBadges.streak(days: logged, today: "2026-11-15", calendar: calendar), 3)
        // Today still being eaten does not break it.
        XCTAssertEqual(FoodBadges.streak(days: Set(days(from: "2026-11-10", count: 5)), today: "2026-11-15", calendar: calendar), 5)
    }

    func testStayingWithItBadges() {
        let logged = days(from: "2026-08-03", count: 100)
        let summary = FoodBadges.summary(countedDays: logged, weekNotes: [:], monthNotes: [:], today: "2026-11-15",
                                         calendar: calendar)
        XCTAssertEqual(summary.earned.first { $0.badge == .firstFullWeek }?.day, "2026-08-09", "the first Sunday of a full week")
        XCTAssertEqual(summary.earned.first { $0.badge == .days30 }?.day, logged[29])
        XCTAssertEqual(summary.earned.first { $0.badge == .days100 }?.day, logged[99])
    }

    func testGoodWeeksAndHabitsNeedSureNotes() {
        let veg = { (points: Double) in [FoodScore.Part(component: .vegetables, points: points, amountPerDay: 5)] }
        let sundays = ["2026-10-18", "2026-10-25", "2026-11-01", "2026-11-08"]
        var weeks = Dictionary(uniqueKeysWithValues: sundays.map { ($0, note($0, score: 7, parts: veg(9))) })
        var summary = FoodBadges.summary(countedDays: [], weekNotes: weeks, monthNotes: [:], today: "2026-11-15", calendar: calendar)
        XCTAssertEqual(summary.earned.first { $0.badge == .habit(.vegetables) }?.day, "2026-11-08")
        XCTAssertNil(summary.earned.first { $0.badge == .goodWeek })

        weeks["2026-11-01"] = note("2026-11-01", score: 9, parts: veg(9), placed: 0.5)
        summary = FoodBadges.summary(countedDays: [], weekNotes: weeks, monthNotes: [:], today: "2026-11-15", calendar: calendar)
        XCTAssertNil(summary.earned.first { $0.badge == .goodWeek }, "an uncertain week earns nothing")
        XCTAssertNil(summary.earned.first { $0.badge == .habit(.vegetables) }, "and it breaks the run of four")

        weeks["2026-11-01"] = note("2026-11-01", score: 8.4, parts: veg(9))
        summary = FoodBadges.summary(countedDays: [], weekNotes: weeks, monthNotes: [:], today: "2026-11-15", calendar: calendar)
        XCTAssertEqual(summary.earned.first { $0.badge == .goodWeek }?.day, "2026-11-01")
        XCTAssertEqual(summary.bestWeek?.day, "2026-11-01")
    }

    func testTheLogFeedsTheSummary() {
        var entries: [FoodLogEntry] = []
        for day in days(from: "2026-11-02", count: 7) {
            let totals: FoodNutrientValues = ["energy_kcal": 2_000]
            entries.append(FoodLogEntry(id: UUID().uuidString, loggedAt: 0, day: day, foodId: "bls:G000000", name: "Gemüse",
                                        grams: 500, per100g: totals, totals: totals, origin: .search, createdAt: 0, updatedAt: 0))
        }
        let summary = FoodBadges.summary(entries: entries, male: true, usualFallbackKcal: 2_000, today: "2026-11-08",
                                         calendar: calendar)
        XCTAssertEqual(summary.streakDays, 7)
        XCTAssertTrue(summary.earned.contains { $0.badge == .firstFullWeek })
        XCTAssertNotNil(summary.bestWeek)
    }
}
