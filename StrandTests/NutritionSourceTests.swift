import XCTest
@testable import Strand

final class NutritionSourceTests: XCTestCase {
    private let alpha = NutritionHealthSource(id: "com.alpha", name: "Alpha")
    private let beta = NutritionHealthSource(id: "com.beta", name: "Beta")

    func testOneHealthWriterIsSelectedWithoutAStoredPreference() {
        let row = NutritionHealthSourceDay(day: "2026-09-30", source: alpha,
                                           calories: 2_100, proteinG: 140,
                                           carbsG: 220, fatG: 70)
        let result = NutritionHealthResolver.resolve([row], preferredSourceId: nil)

        XCTAssertEqual(result.days, [row])
        XCTAssertEqual(result.availableSources, [alpha])
        XCTAssertTrue(result.unresolvedDays.isEmpty)
    }

    func testTwoHealthWritersAreNeverSummedWithoutASelection() {
        let rows = [
            NutritionHealthSourceDay(day: "2026-09-30", source: alpha,
                                     calories: 2_100, proteinG: 140, carbsG: nil, fatG: nil),
            NutritionHealthSourceDay(day: "2026-09-30", source: beta,
                                     calories: 2_000, proteinG: 130, carbsG: nil, fatG: nil),
        ]
        let result = NutritionHealthResolver.resolve(rows, preferredSourceId: nil)

        XCTAssertTrue(result.days.isEmpty)
        XCTAssertEqual(result.unresolvedDays, ["2026-09-30"])
    }

    func testPreferredWriterWinsAndItsMacrosStayTogether() {
        let rows = [
            NutritionHealthSourceDay(day: "2026-09-30", source: alpha,
                                     calories: 2_100, proteinG: 140, carbsG: 220, fatG: 70),
            NutritionHealthSourceDay(day: "2026-09-30", source: beta,
                                     calories: 1_600, proteinG: 80, carbsG: 160, fatG: 50),
        ]
        let result = NutritionHealthResolver.resolve(rows, preferredSourceId: beta.id)

        XCTAssertEqual(result.days, [rows[1]])
        XCTAssertTrue(result.unresolvedDays.isEmpty)
    }

    func testSingleFallbackWriterIsUsedWhenPreferredHasNoDataThatDay() {
        let row = NutritionHealthSourceDay(day: "2026-09-30", source: beta,
                                           calories: 1_900, proteinG: nil,
                                           carbsG: nil, fatG: nil)
        let result = NutritionHealthResolver.resolve([row], preferredSourceId: alpha.id)

        XCTAssertEqual(result.days, [row])
        XCTAssertTrue(result.unresolvedDays.isEmpty)
    }
}
