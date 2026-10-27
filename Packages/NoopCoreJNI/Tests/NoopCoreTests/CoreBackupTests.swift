import XCTest
import NoopCore
import StrandCore
import WhoopStore

/// An Android backup goes through the Apple `.noopbak` path and comes back with the same rows.
final class CoreBackupTests: XCTestCase {
    func testAnExportedStoreRestoresWithTheSameDays() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("core-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourcePath = dir.appendingPathComponent("source.sqlite").path
        let source = try await WhoopStore(path: sourcePath)
        let written = try await CoreDemo.seedIfEmpty(store: source, deviceId: "my-whoop")
        XCTAssertEqual(written, CoreDemo.days)

        let backup = dir.appendingPathComponent("noop.noopbak").path
        let exported = await CoreBackup.export(store: source, dbPath: sourcePath, to: backup, scratch: dir.path,
                                               appVersion: "12.2.1", appBuild: "1")
        XCTAssertEqual(exported, .done)

        let targetPath = dir.appendingPathComponent("target.sqlite").path
        _ = try await WhoopStore(path: targetPath)   // an existing, empty store, as on a phone with the app installed
        XCTAssertEqual(CoreBackup.restore(from: backup, toDatabaseAt: targetPath, scratch: dir.path), .imported)

        let restored = try await WhoopStore(path: targetPath)
        let before = try await source.dailyMetrics(deviceId: "my-whoop-noop", from: "0000-01-01", to: "9999-12-31")
        let after = try await restored.dailyMetrics(deviceId: "my-whoop-noop", from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(after, before)
        let ownsInputs = try await restored.ownsAndroidJournalHydration()
        XCTAssertTrue(ownsInputs, "Restoring an archive must never replay this phone's old Room inputs")
    }

    func testAFileThatIsNoBackupIsRefusedAndTheStoreKept() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("core-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let targetPath = dir.appendingPathComponent("target.sqlite").path
        _ = try await WhoopStore(path: targetPath)
        let junk = dir.appendingPathComponent("junk.noopbak")
        try Data("not a backup".utf8).write(to: junk)
        XCTAssertEqual(CoreBackup.restore(from: junk.path, toDatabaseAt: targetPath, scratch: dir.path),
                       .failed("notSQLite"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetPath))
    }
}
