import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// A store created by upstream NOOP must open under this fork with its history intact.
///
/// The resources are `.dump`s of real stores written by the upstream release tags' own WhoopStore
/// (a WHOOP 5 MG with ten unlabelled beats, ten labelled v18 beats at +100 s and one scored day). Before
/// `UpstreamMigrationBridge`, opening either failed on "duplicate column name: burstIndex", because
/// upstream's v38–v45 are recorded under identifiers the fork gives other numbers.
final class UpstreamStoreUpgradeTests: XCTestCase {
    private let base = 1_780_000_000

    private func openUpstreamStore(_ resource: String) async throws -> WhoopStore {
        let url = try XCTUnwrap(Bundle.module.url(forResource: resource, withExtension: "sql"))
        let dump = try String(contentsOf: url, encoding: .utf8)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(resource)-\(UUID().uuidString).sqlite").path
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let queue = try DatabaseQueue(path: path)
        try queue.inDatabase { try $0.execute(sql: dump) }
        try queue.close()
        return try await WhoopStore(path: path)
    }

    private func assertHistoryIntact(_ store: WhoopStore, expectedBeats: Int,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let rr = try await store.rrIntervals(deviceId: "my-whoop", from: base, to: base + 200, limit: 1_000)
        XCTAssertEqual(rr.count, expectedBeats, "unlabelled beats must be read, not withheld", file: file, line: line)
        let daily = try await store.dailyMetrics(deviceId: "my-whoop-noop", from: "2026-06-01", to: "2026-06-01")
        XCTAssertEqual(daily.first?.avgHrv, 48.5, "a scored day survives the upgrade", file: file, line: line)
        let fromUpstream = try await store.openedFromUpstreamMigrations()
        XCTAssertTrue(fromUpstream, file: file, line: line)
    }

    func testAnUpstream11_5StoreOpensWithItsHistory() async throws {
        let store = try await openUpstreamStore("upstream_v11_5_0_store")
        // 11.5 predates source labels, so all twenty beats are unlabelled and all are read.
        try await assertHistoryIntact(store, expectedBeats: 20)
    }

    func testAnUpstream11_7StoreOpensWithItsHistory() async throws {
        let store = try await openUpstreamStore("upstream_v11_7_0_store")
        // Upstream 11.7 reads only the ten labelled beats back; the fork reads both halves.
        try await assertHistoryIntact(store, expectedBeats: 20)
    }

    /// Re-opening must be a no-op: the bridge records identifiers once and the migrator finds nothing to do.
    func testReopeningABridgedStoreIsStable() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "upstream_v11_7_0_store", withExtension: "sql"))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reopen-\(UUID().uuidString).sqlite").path
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let queue = try DatabaseQueue(path: path)
        try queue.inDatabase { try $0.execute(sql: try String(contentsOf: url, encoding: .utf8)) }
        try queue.close()
        _ = try await WhoopStore(path: path)
        let reopened = try await WhoopStore(path: path)
        let rr = try await reopened.rrIntervals(deviceId: "my-whoop", from: base, to: base + 200, limit: 1_000)
        XCTAssertEqual(rr.count, 20)
    }

    /// A store the fork created itself is never mistaken for an upstream one.
    func testAForkStoreIsNotReportedAsUpstream() async throws {
        let store = try await WhoopStore.inMemory()
        let fromUpstream = try await store.openedFromUpstreamMigrations()
        XCTAssertFalse(fromUpstream)
    }

    /// The repair pass bound: the earliest night with sleep but no HRV, from a given day on.
    func testEarliestSleptDayMissingHRV() async throws {
        let store = try await WhoopStore.inMemory()
        func day(_ key: String, sleep: Double?, hrv: Double?) -> DailyMetric {
            DailyMetric(day: key, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: nil, avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil)
        }
        _ = try await store.upsertDailyMetrics([
            day("2026-08-10", sleep: 400, hrv: nil),   // before the window start
            day("2026-08-25", sleep: 0, hrv: nil),     // not worn
            day("2026-08-27", sleep: 410, hrv: 44),    // scored
            day("2026-08-29", sleep: 420, hrv: nil),   // blanked
        ], deviceId: "my-whoop-noop")
        let earliest = try await store.earliestSleptDayMissingHRV(deviceId: "my-whoop-noop", since: "2026-08-21")
        XCTAssertEqual(earliest, "2026-08-29")
    }
}
