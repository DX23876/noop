import XCTest
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
        let outcome = BackupArchive.restore(from: backup, toDatabaseAt: live.path, scratchRoot: dir,
                                            applySettings: { appliedSettings = $0 })
        guard case .imported(let sidecar) = outcome else { return XCTFail("restore failed: \(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "the previous store is kept beside")
        XCTAssertEqual(appliedSettings, Data("{}".utf8))

        let restored = try await WhoopStore(path: live.path)
        let days = try await restored.dailyMetrics(deviceId: "my-whoop", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(days.map(\.day), ["2026-10-01"], "the backup's rows replaced the live store's")
    }

    func testAFileThatIsNotABackupLeavesTheStoreAlone() async throws {
        let live = try await store(at: "live.sqlite", day: "2026-09-01")
        let junk = dir.appendingPathComponent("junk.noopbak")
        try Data("not a backup".utf8).write(to: junk)
        let outcome = BackupArchive.restore(from: junk, toDatabaseAt: live.path, scratchRoot: dir,
                                            applySettings: { _ in XCTFail("no settings from a failed restore") })
        guard case .failure(.notSQLite) = outcome else { return XCTFail("expected notSQLite, got \(outcome)") }
    }

    func testTheOriginOfABackupComesFromItsMigratorTable() {
        XCTAssertEqual(BackupArchive.backupOrigin(of: ["grdb_migrations", "device"]), .mac)
        XCTAssertEqual(BackupArchive.backupOrigin(of: ["room_master_table"]), .android)
        XCTAssertEqual(BackupArchive.backupOrigin(of: ["android_metadata", "sqlite_sequence"]), .android)
        XCTAssertEqual(BackupArchive.backupOrigin(of: []), .unknown)
    }
}
