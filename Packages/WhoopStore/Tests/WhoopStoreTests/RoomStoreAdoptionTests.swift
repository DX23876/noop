import XCTest
import GRDB
@testable import WhoopStore

/// Fork (DX23876), Android without Room: an Android Room store copied into the core's store by column name.
final class RoomStoreAdoptionTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        for path in paths {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
    }

    private func tempPath(_ name: String) -> String {
        let path = NSTemporaryDirectory() + "\(name)-\(UUID().uuidString).sqlite"
        paths.append(path)
        return path
    }

    /// A Room store as an older Android build left it: Room's bookkeeping, `battery` in Room's column order,
    /// `rrInterval` without the later `transport` column, Kotlin's computed rows, tombstones and a table the
    /// core does not have.
    private func roomStore() throws -> String {
        let path = tempPath("room")
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT);
                CREATE TABLE android_metadata (locale TEXT);
                PRAGMA user_version = 42;
                CREATE TABLE hrSample (deviceId TEXT NOT NULL, ts INTEGER NOT NULL, bpm INTEGER NOT NULL,
                    synced INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (deviceId, ts));
                CREATE TABLE battery (deviceId TEXT NOT NULL, ts INTEGER NOT NULL, soc REAL, mv INTEGER,
                    charging INTEGER, synced INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (deviceId, ts));
                CREATE TABLE rrInterval (deviceId TEXT NOT NULL, ts INTEGER NOT NULL, rrMs INTEGER NOT NULL,
                    seq INTEGER NOT NULL DEFAULT 0, synced INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (deviceId, ts, rrMs, seq));
                CREATE TABLE dailyMetric (deviceId TEXT NOT NULL, day TEXT NOT NULL, recovery REAL,
                    PRIMARY KEY (deviceId, day));
                CREATE TABLE sleepSession (deviceId TEXT NOT NULL, startTs INTEGER NOT NULL, endTs INTEGER NOT NULL,
                    userEdited INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (deviceId, startTs));
                CREATE TABLE dismissedSleep (deviceId TEXT NOT NULL, startTs INTEGER NOT NULL, endTs INTEGER NOT NULL,
                    managementVisible INTEGER NOT NULL, PRIMARY KEY (deviceId, startTs));
                CREATE TABLE dismissedWorkout (deviceId TEXT NOT NULL, startTs INTEGER NOT NULL,
                    endTs INTEGER NOT NULL, PRIMARY KEY (deviceId, startTs));
                CREATE TABLE liftExercise (id TEXT PRIMARY KEY, deviceId TEXT NOT NULL, name TEXT NOT NULL,
                    createdAt INTEGER NOT NULL);
                CREATE TABLE coachMessage (id INTEGER PRIMARY KEY, text TEXT);
                """)
            // Raw data from 2025-10-10 00:00 UTC (1760054400).
            try db.execute(sql: "INSERT INTO hrSample VALUES ('S', 1760054400, 61, 0), ('S', 1760054401, 62, 0)")
            try db.execute(sql: "INSERT INTO battery VALUES ('S', 1760054400, 80.5, 3900, 1, 0)")
            try db.execute(sql: "INSERT INTO rrInterval VALUES ('S', 1760054400, 980, 0, 0)")
            try db.execute(sql: """
                INSERT INTO dailyMetric VALUES ('S-noop', '2025-10-09', 0.7), ('S-noop', '2025-10-10', 0.5),
                    ('whoop-csv', '2025-10-10', 0.66)
                """)
            try db.execute(sql: """
                INSERT INTO sleepSession VALUES ('S-noop', 1760000000, 1760020000, 0),
                    ('S-noop', 1760080000, 1760100000, 1), ('S-noop', 1760160000, 1760180000, 0)
                """)
            try db.execute(sql: "INSERT INTO dismissedSleep VALUES ('S-noop', 100, 200, 1), ('S', 300, 400, 0)")
            try db.execute(sql: "INSERT INTO dismissedWorkout VALUES ('S-noop', 500, 600)")
            try db.execute(sql: "INSERT INTO liftExercise VALUES ('e1', 'S', 'Squat', 1760054400)")
            try db.execute(sql: "INSERT INTO coachMessage VALUES (1, 'hi')")
        }
        try queue.close()
        return path
    }

    func testARoomStoreIsCopiedByColumnNameWithTheCoresDerivedRules() async throws {
        let store = try await WhoopStore(path: tempPath("core"))
        let report = try await store.adoptRoomStore(atPath: try roomStore())

        XCTAssertEqual(report.roomVersion, 42)
        XCTAssertEqual(report.copiedRows["hrSample"], 2)
        XCTAssertEqual(report.skipped["coachMessage"], "androidOnly")
        XCTAssertEqual(report.dismissedSleepTokens, ["100:200", "300:400"])
        XCTAssertEqual(report.hiddenDismissedSleepTokens, ["300:400"])
        XCTAssertEqual(report.dismissedWorkoutTokens, ["500:600"])

        try await store.dbWriter.read { db in
            // Room's order puts `charging` before `synced`; the copy goes by name.
            let battery = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT charging, synced, soc FROM battery"))
            XCTAssertEqual(battery["charging"] as Int, 1)
            XCTAssertEqual(battery["synced"] as Int, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval WHERE transport IS NULL"), 1)
            // Kotlin's score before the raw history stays; the one after it is the core's to compute.
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT deviceId || '/' || day FROM dailyMetric ORDER BY 1"),
                           ["S-noop/2025-10-09", "whoop-csv/2025-10-10"])
            // The night before the raw data and the edited night stay; the unedited computed night goes.
            XCTAssertEqual(try Int.fetchAll(db, sql: "SELECT startTs FROM sleepSession ORDER BY startTs"),
                           [1760000000, 1760080000])
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT name FROM liftExercise"), ["Squat"])
        }
        let recipe = try await store.cursor("noopai:analysisRecipeVersion")
        XCTAssertEqual(recipe, 0, "the adopted store's derived tables are rebuilt from the first step")
    }

    func testRowsTheCoreAlreadyHoldsWinAndLiftsAreLeftToACoreThatLogsThem() async throws {
        let store = try await WhoopStore(path: tempPath("core"))
        try await store.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('S', 1760054400, 70)")
            try db.execute(sql: "INSERT INTO liftExercise (id, deviceId, name, createdAt) VALUES ('c1', 'S', 'Bench', 1)")
        }
        let report = try await store.adoptRoomStore(atPath: try roomStore())

        XCTAssertEqual(report.copiedRows["hrSample"], 1)
        XCTAssertEqual(report.skipped["liftExercise"], "coreHasRows")
        try await store.dbWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT bpm FROM hrSample WHERE ts = 1760054400"), 70)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT name FROM liftExercise"), ["Bench"])
        }
    }

    func testAFileThatIsNotARoomStoreIsRefusedAndLeavesTheStoreAlone() async throws {
        let other = tempPath("other")
        let queue = try DatabaseQueue(path: other)
        try await queue.write { db in try db.execute(sql: "CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER)") }
        try queue.close()
        let store = try await WhoopStore(path: tempPath("core"))
        do {
            _ = try await store.adoptRoomStore(atPath: other)
            XCTFail("expected notRoom")
        } catch let error as RoomStoreAdoption.AdoptionError {
            XCTAssertEqual(error, .notRoom)
        }
        let recipe = try await store.cursor("noopai:analysisRecipeVersion")
        XCTAssertNotEqual(recipe, 0)
    }
}
