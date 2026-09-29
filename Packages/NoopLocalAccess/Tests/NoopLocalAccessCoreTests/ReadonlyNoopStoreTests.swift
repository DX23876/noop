import GRDB
import XCTest
@testable import NoopLocalAccessCore

final class ReadonlyNoopStoreTests: XCTestCase {
    func testReadsSeededNoopStoreWithoutOpeningWritableHandle() throws {
        let url = try TemporaryDatabase.seeded()
        let store = try ReadonlyNoopStore(path: url.path)

        XCTAssertTrue(try store.isReadOnlyForTest())
        XCTAssertEqual(try store.latestHRSampleTs(deviceId: "my-whoop"), 102)
        XCTAssertEqual(try store.metricKeys(deviceId: "my-whoop"), ["hrv"])

        let daily = try store.dailyMetrics(deviceId: "my-whoop", from: "2026-06-01", to: "2026-06-30")
        XCTAssertEqual(daily.map(\.day), ["2026-06-10"])
        XCTAssertEqual(daily.first?.recovery, 67)

        let stats = try store.storageStats()
        XCTAssertEqual(stats.decodedRows, 4)
        XCTAssertEqual(stats.rawBatches, 1)
        XCTAssertEqual(stats.rawBytes, 12)
    }

    /// A day the strap energy model priced carries its active energy beside the retired estimate, from
    /// the buckets of the device that covered the day most fully; a day it did not price carries nil.
    func testDailyRowsCarryTheModelsActiveEnergy() throws {
        let url = try TemporaryDatabase.seeded()
        let writer = try DatabaseQueue(path: url.path)
        try writer.write { db in
            try db.execute(sql: """
                CREATE TABLE whoopEnergyBucket(deviceId TEXT NOT NULL, day TEXT NOT NULL,
                    bucketStart INTEGER NOT NULL, durationSeconds INTEGER NOT NULL, basalKcal DOUBLE NOT NULL,
                    activeKcal DOUBLE NOT NULL, context TEXT NOT NULL, evidence TEXT NOT NULL,
                    uncertaintyFraction DOUBLE NOT NULL, PRIMARY KEY(deviceId, bucketStart))
                """)
            for (index, active) in [10.0, 20.0, 30.0].enumerated() {
                try db.execute(sql: "INSERT INTO whoopEnergyBucket VALUES ('strap', '2026-06-10', ?, 300, 11, ?, 'locomotion', 'observed', 0.2)",
                               arguments: [index * 300, active])
            }
            try db.execute(sql: "INSERT INTO whoopEnergyBucket VALUES ('other', '2026-06-10', 9000, 300, 11, 500, 'locomotion', 'observed', 0.2)")
        }
        let store = try ReadonlyNoopStore(path: url.path)
        let daily = try store.dailyMetrics(deviceId: "my-whoop", from: "2026-06-01", to: "2026-06-30")
        XCTAssertEqual(daily.first?.activeKcal, 60)
    }

    func testForeignNoopLikeDatabaseIsRejectedWithoutQuarantine() throws {
        let url = try TemporaryDatabase.foreignNoopLike()

        XCTAssertThrowsError(try ReadonlyNoopStore(path: url.path)) { error in
            guard case .databaseUnavailable(let message) = error as? LocalAccessError else {
                return XCTFail("Expected LocalAccessError.databaseUnavailable")
            }
            XCTAssertTrue(message.contains("without GRDB migration metadata"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
