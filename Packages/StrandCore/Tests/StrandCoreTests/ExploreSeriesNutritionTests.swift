import XCTest
@testable import StrandCore
import WhoopStore

/// What one day ate is answered in ONE place (`NutritionReads`), and every reader of the four nutrition keys
/// goes through it. Until 2026-11-19 the Explore read took the catalogue's lane alone, so a wearer who logs
/// food in the app saw the days on the Food page and nowhere else: the Today tile and the measure's own page
/// read the CSV import lane, found nothing, and said "No data yet" over seven logged days.
final class ExploreSeriesNutritionTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("explore-nutrition-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func reader(_ store: WhoopStore) -> StoreReader {
        StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: ["my-whoop"])
    }

    func testEveryIntakeLaneReachesTheMeasuresSeriesInItsOwnOrder() async throws {
        let store = try await WhoopStore.inMemory()
        // A CSV import on the first two days, the food log on the second and third. The food log is the
        // more deliberate source, so it wins the day they share.
        _ = try await store.upsertMetricSeries([
            .init(day: "2026-11-10", key: NutritionReads.caloriesKey, value: 1_900),
            .init(day: "2026-11-11", key: NutritionReads.caloriesKey, value: 2_000),
            .init(day: "2026-11-10", key: NutritionReads.proteinKey, value: 100),
        ], deviceId: NutritionReads.csvIntakeSource)
        _ = try await store.upsertMetricSeries([
            .init(day: "2026-11-11", key: NutritionReads.caloriesKey, value: 2_222),
            .init(day: "2026-11-12", key: NutritionReads.caloriesKey, value: 2_333),
            .init(day: "2026-11-12", key: NutritionReads.proteinKey, value: 155),
        ], deviceId: WhoopStore.foodLogSourceId)

        let read = reader(store)
        let calories = await read.exploreSeries(key: NutritionReads.caloriesKey, source: NutritionReads.csvIntakeSource,
                                                from: "2026-11-01", to: "2026-11-30",
                                                dailyRows: [], suppressedSleepWakeDays: [])
        XCTAssertEqual(calories.map(\.day), ["2026-11-10", "2026-11-11", "2026-11-12"],
                       "a day only the food log carries is a day the measure has")
        XCTAssertEqual(calories.map(\.value), [1_900, 2_222, 2_333], "the food log outranks the import on a shared day")

        let protein = await read.exploreSeries(key: NutritionReads.proteinKey, source: NutritionReads.csvIntakeSource,
                                               from: "2026-11-01", to: "2026-11-30",
                                               dailyRows: [], suppressedSleepWakeDays: [])
        XCTAssertEqual(protein.map(\.day), ["2026-11-10", "2026-11-12"])
        XCTAssertEqual(protein.map(\.value), [100, 155])
    }

    func testTheSourceAskedForDoesNotChangeTheAnswer() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMetricSeries([
            .init(day: "2026-11-12", key: NutritionReads.caloriesKey, value: 2_100),
        ], deviceId: WhoopStore.foodLogSourceId)
        let read = reader(store)
        for source in [NutritionReads.csvIntakeSource, MetricResolver.appleHealthSource, "my-whoop"] {
            let series = await read.exploreSeries(key: NutritionReads.caloriesKey, source: source,
                                                  from: "2026-11-01", to: "2026-11-30",
                                                  dailyRows: [], suppressedSleepWakeDays: [])
            XCTAssertEqual(series.map(\.value), [2_100], "asked through \(source)")
        }
    }
}
