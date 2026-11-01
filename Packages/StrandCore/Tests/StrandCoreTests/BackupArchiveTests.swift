import XCTest
import GRDB
import StrandCore
import WhoopStore

/// A `.noopbak` written by the core restores through the core, on every platform the core runs on: the archive
/// verifies after writing, the restore keeps the previous store beside the new one, and a settings entry reaches
/// the caller only after the swap.
final class BackupArchiveTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(at name: String, day: String) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let store = try await WhoopStore(path: url.path)
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: day, totalSleepMin: 420, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: 50, avgHrv: 70, recovery: 80, strain: nil,
                        exerciseCount: nil)
        ], deviceId: "my-whoop")
        try await store.checkpointWAL()
        return url
    }

    func testAWrittenBackupVerifiesAndRestoresOverAnotherStore() async throws {
        let source = try await store(at: "source.sqlite", day: "2026-10-01")
        let live = try await store(at: "live.sqlite", day: "2026-09-01")
        let backup = dir.appendingPathComponent("NOOP.noopbak")
        try BackupArchive.writeVerified(dbURL: source, to: backup, settingsJSON: Data("{}".utf8),
                                        manifestJSON: BackupArchive.manifestJSON(appVersion: "1", appBuild: "1",
                                                                                platform: "test"),
                                        scratchRoot: dir)
        XCTAssertEqual(BackupArchive.verifyWritten(at: backup), .intact)

        var appliedSettings: Data?
        var replacedBeforeSwap: Bool?
        let outcome = BackupArchive.restore(from: backup, toDatabaseAt: live.path, scratchRoot: dir,
                                            willReplaceDatabase: {
                                                // Called while the live file is still the old store.
                                                replacedBeforeSwap = FileManager.default.fileExists(atPath: live.path)
                                            },
                                            applySettings: { appliedSettings = $0 })
        XCTAssertEqual(replacedBeforeSwap, true, "an open store hears of the swap before its file goes")
        guard case .imported(let sidecar) = outcome else { return XCTFail("restore failed: \(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "the previous store is kept beside")
        XCTAssertEqual(appliedSettings, Data("{}".utf8))

        let restored = try await WhoopStore(path: live.path)
        let days = try await restored.dailyMetrics(deviceId: "my-whoop", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(days.map(\.day), ["2026-10-01"], "the backup's rows replaced the live store's")
    }

    /// The rollback copy kept beside a restore holds the live store as it stood, including rows committed into
    /// the WAL but not yet checkpointed into the main file while the store is open.
    func testTheRollbackCopyIncludesRowsStillInTheWAL() async throws {
        let source = try await store(at: "source.sqlite", day: "2026-10-01")
        let liveURL = dir.appendingPathComponent("live.sqlite")
        let live = try await WhoopStore(path: liveURL.path)
        _ = try await live.upsertDailyMetrics([
            DailyMetric(day: "2026-09-02", totalSleepMin: 400, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: 52, avgHrv: 65, recovery: 70, strain: nil,
                        exerciseCount: nil)
        ], deviceId: "my-whoop")
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveURL.path + "-wal"), "precondition: a WAL is open")
        let backup = dir.appendingPathComponent("NOOP.noopbak")
        try BackupArchive.writeVerified(dbURL: source, to: backup, settingsJSON: Data("{}".utf8),
                                        manifestJSON: BackupArchive.manifestJSON(appVersion: "1", appBuild: "1",
                                                                                platform: "test"),
                                        scratchRoot: dir)
        let outcome = BackupArchive.restore(from: backup, toDatabaseAt: liveURL.path, scratchRoot: dir,
                                            applySettings: { _ in })
        guard case .imported(let sidecar) = outcome else { return XCTFail("restore failed: \(outcome)") }
        _ = live
        let kept = try await WhoopStore(path: sidecar.path)
        let days = try await kept.dailyMetrics(deviceId: "my-whoop", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(days.map(\.day), ["2026-09-02"], "the rollback copy holds the row that was only in the WAL")
    }

    func testAFileThatIsNotABackupLeavesTheStoreAlone() async throws {
        let live = try await store(at: "live.sqlite", day: "2026-09-01")
        let junk = dir.appendingPathComponent("junk.noopbak")
        try Data("not a backup".utf8).write(to: junk)
        let outcome = BackupArchive.restore(from: junk, toDatabaseAt: live.path, scratchRoot: dir,
                                            willReplaceDatabase: { XCTFail("a refused file never swaps the store") },
                                            applySettings: { _ in XCTFail("no settings from a failed restore") })
        guard case .failure(.notSQLite) = outcome else { return XCTFail("expected notSQLite, got \(outcome)") }
    }

    /// A Room store zipped as an Android `.noopbak`: Room's bookkeeping and one heart-rate second.
    private func roomBackup() throws -> URL {
        let room = dir.appendingPathComponent("room.sqlite")
        let queue = try DatabaseQueue(path: room.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT);
                CREATE TABLE hrSample (deviceId TEXT NOT NULL, ts INTEGER NOT NULL, bpm INTEGER NOT NULL,
                    synced INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (deviceId, ts));
                CREATE TABLE dismissedWorkout (deviceId TEXT NOT NULL, startTs INTEGER NOT NULL,
                    endTs INTEGER NOT NULL, PRIMARY KEY (deviceId, startTs));
                INSERT INTO hrSample VALUES ('aa:bb', 1760054400, 61, 0);
                INSERT INTO dismissedWorkout VALUES ('aa:bb-noop', 10, 20);
                """)
        }
        try queue.close()
        let backup = dir.appendingPathComponent("android.noopbak")
        try BackupArchive.writeZip(dbURL: room, to: backup, settingsJSON: nil,
                                   manifestJSON: BackupArchive.manifestJSON(appVersion: "1", appBuild: "1",
                                                                           platform: "android"),
                                   scratchRoot: dir)
        return backup
    }

    func testARoomBackupIsRefusedWithoutAConverterAndRestoresThroughOne() async throws {
        let live = try await store(at: "live.sqlite", day: "2026-09-01")
        let backup = try roomBackup()
        let refused = BackupArchive.restore(from: backup, toDatabaseAt: live.path, scratchRoot: dir,
                                            applySettings: { _ in })
        guard case .failure(.foreignBackup) = refused else { return XCTFail("expected foreignBackup, got \(refused)") }

        var report: RoomStoreAdoption.Report?
        let outcome = BackupArchive.restore(from: backup, toDatabaseAt: live.path, scratchRoot: dir,
                                            adoptRoomStore: { room, destination in
                                                report = try RoomStoreAdoption.convert(roomPath: room.path,
                                                                                       toStoreAt: destination.path)
                                            },
                                            applySettings: { _ in })
        guard case .imported = outcome else { return XCTFail("restore failed: \(outcome)") }
        XCTAssertEqual(report?.copiedRows["hrSample"], 1)
        XCTAssertEqual(report?.dismissedWorkoutTokens, ["10:20"])

        let restored = try await WhoopStore(path: live.path)
        let samples = try await restored.hrSamples(deviceId: "aa:bb", from: 0, to: Int.max, limit: 10)
        XCTAssertEqual(samples.map(\.bpm), [61], "the Room backup's history is the store now")
        let recipe = try await restored.cursor("noopai:analysisRecipeVersion")
        XCTAssertEqual(recipe, 0)
    }

    func testTheOriginOfABackupComesFromItsMigratorTable() {
        XCTAssertEqual(BackupArchive.backupOrigin(of: ["grdb_migrations", "device"]), .mac)
        XCTAssertEqual(BackupArchive.backupOrigin(of: ["room_master_table"]), .android)
        XCTAssertEqual(BackupArchive.backupOrigin(of: ["android_metadata", "sqlite_sequence"]), .android)
        XCTAssertEqual(BackupArchive.backupOrigin(of: []), .unknown)
    }
}
