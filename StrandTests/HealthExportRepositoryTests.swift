import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class HealthExportRepositoryTests: XCTestCase {
    private func row(_ start: Int, source: String = "manual", sport: String = "Running") -> WorkoutRow {
        .init(startTs: start, endTs: start + 600, sport: sport, source: source, durationS: 550,
              energyKcal: 100, avgHr: 130, maxHr: 150, strain: nil, distanceM: 1000,
              zonesJSON: nil, notes: nil, steps: nil)
    }

    func testManualCorrectionWinsOneIdentityAndLegacyHealthIsExcluded() {
        let manual = row(100)
        let detected = row(100, source: "my-whoop-noop")
        let legacyHealth = row(200, source: "apple_health")
        XCTAssertEqual(Repository.healthExportWorkoutRows([manual, detected, legacyHealth]), [manual])
        XCTAssertEqual(Repository.healthExportWorkoutRows([detected, manual, legacyHealth]), [manual])
    }

    func testSameStartDifferentSportsHaveSeparateIdentities() {
        XCTAssertEqual(Repository.healthExportWorkoutRows([row(100), row(100, sport: "Walking")]).count, 2)
    }

    func testExportReadsMoreThanFiveHundredRowsIncludingRetainedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        try await store.upsertWorkouts((1...501).map { row($0 * 1000) }, deviceId: "my-whoop")
        try await store.upsertWorkouts([row(600_000)], deviceId: "whoop-retained")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        // Registered physical ids are the same union resolver the charts and deletions use.
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(PairedDevice(id: "whoop-retained", brand: "WHOOP", model: "5.0",
            sourceKind: .liveBLE, capabilities: [.hr], status: .archived, addedAt: 1, lastSeenAt: 1))
        let rows = try await repo.healthExportWorkouts(from: 0, to: 700_000)
        XCTAssertEqual(rows.count, 502)
        XCTAssertTrue(rows.contains { $0.startTs == 600_000 })
    }
}
