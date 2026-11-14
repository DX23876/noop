import Foundation
import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

/// The first-run question both Today screens ask before they offer to connect a wearable. iOS reads
/// `repo.days.isEmpty`; Android asks the core. The two must be the same question, so this holds
/// `hasAnyDay` against `dailyRows` itself rather than against a second rule.
@MainActor
final class CoreFirstRunTests: XCTestCase {

    private func reader(_ store: WhoopStore) -> StoreReader {
        StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
    }

    func testAnEmptyStoreHasNoDay() async throws {
        let store = try await WhoopStore.inMemory()
        let r = reader(store)
        let any = await CoreRead.hasAnyDay(reader: r)
        let rows = await CoreRead.dailyRows(from: "2016-01-01", to: LogicalDay.key(Date()), reader: r)
        XCTAssertFalse(any)
        XCTAssertTrue(rows.isEmpty)
    }

    /// The case the tester hit: heart rate landed and a day exists, but no night has been scored, so the day
    /// carries neither a Rest nor a Charge value. The old Android rule asked for exactly those and kept
    /// offering to pair a strap that had been streaming for an hour.
    func testADayWithoutAScoreStillCounts() async throws {
        let store = try await WhoopStore.inMemory()
        let r = reader(store)
        let today = LogicalDay.key(Date())
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: today, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: 52, avgHrv: nil, recovery: nil,
                        strain: nil, exerciseCount: nil),
        ], deviceId: "my-whoop")
        let any = await CoreRead.hasAnyDay(reader: r)
        let rows = await CoreRead.dailyRows(from: "2016-01-01", to: today, reader: r)
        XCTAssertTrue(any)
        XCTAssertFalse(rows.isEmpty)
    }

    func testTheBridgeAnswersTheSameQuestion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("firstrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            ShadowSession.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertEqual(ShadowSession.start(path: dir.appendingPathComponent("core.sqlite").path,
                                           deviceId: "my-whoop"), 0)
        let store = try XCTUnwrap(ShadowSession.storeAndPath?.0)

        let empty = await CoreCall.run("read.hasAnyDay", "{}")
        XCTAssertEqual(try JSONDecoder().decode([String: Bool].self, from: Data(empty.utf8))["any"], false)

        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: LogicalDay.key(Date()), totalSleepMin: nil, efficiency: nil, deepMin: nil,
                        remMin: nil, lightMin: nil, disturbances: nil, restingHr: 52, avgHrv: nil,
                        recovery: nil, strain: nil, exerciseCount: nil),
        ], deviceId: "my-whoop")
        let filled = await CoreCall.run("read.hasAnyDay", "{}")
        XCTAssertEqual(try JSONDecoder().decode([String: Bool].self, from: Data(filled.utf8))["any"], true)
    }
}
