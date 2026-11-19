import XCTest
@testable import NoopCore
import StrandCore
import WhoopStore

/// The Today tile and the measure's own page must hold the same days for the four nutrition keys. The tile
/// takes the gallery's lane as its first source, so this is the test that the lane no longer decides the
/// answer: `NutritionReads` does, for every reader.
final class TileHistoryNutritionTests: XCTestCase {
    func testTheTileReadsTheFoodLogWithoutBeingToldToLookThere() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMetricSeries([
            .init(day: "2026-11-12", key: NutritionReads.caloriesKey, value: 2_100),
            .init(day: "2026-11-13", key: NutritionReads.caloriesKey, value: 1_980),
            .init(day: "2026-11-12", key: NutritionReads.proteinKey, value: 148),
        ], deviceId: WhoopStore.foodLogSourceId)
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: ["my-whoop"])

        let calories = await reader.tileHistory(key: NutritionReads.caloriesKey, from: "2026-11-01", to: "2026-11-30",
                                                dailyRows: [], suppressedSleepWakeDays: [])
        XCTAssertEqual(calories.days, ["2026-11-12", "2026-11-13"])
        XCTAssertEqual(calories.values, [2_100, 1_980])

        let protein = await reader.tileHistory(key: NutritionReads.proteinKey, from: "2026-11-01", to: "2026-11-30",
                                               dailyRows: [], suppressedSleepWakeDays: [])
        XCTAssertEqual(protein.days, ["2026-11-12"])
        XCTAssertEqual(protein.values, [148])
    }

    func testTheGalleryStillNamesTheseTwoUnderFood() {
        XCTAssertEqual(TileMeasures.all.filter { $0.section == .food }.map(\.key),
                       [NutritionReads.caloriesKey, NutritionReads.proteinKey])
    }
}
