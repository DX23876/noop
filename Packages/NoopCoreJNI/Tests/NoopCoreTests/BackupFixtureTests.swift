import XCTest
import NoopCore
import StrandCore
import WhoopStore

/// Android plan E-5: a backup from either platform restores on the other with identical rows. The fixtures are
/// versioned and never regenerated in place: `android-v1.noopbak` was exported by the Android demo build through
/// the Forge More screen (2026-10-25), `apple-v1.noopbak` was written by the shared `BackupArchive` with the
/// Apple manifest from the same demo history. Both restore here through `CoreBackup`, the Android import path,
/// which is the same `BackupArchive.restore` the Apple apps call.
final class BackupFixtureTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "noopbak", subdirectory: "Fixtures")).path
    }

    private func restored(_ name: String) async throws -> [DailyMetric] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("noop-core.sqlite").path
        _ = try await WhoopStore(path: path)
        let source = try fixture(name)
        XCTAssertEqual(CoreBackup.restore(from: source, toDatabaseAt: path, scratch: dir.path), .imported, name)
        let store = try await WhoopStore(path: path)
        return try await store.dailyMetrics(deviceId: "my-whoop-noop", from: "0000-01-01", to: "9999-12-31")
    }

    func testAnAndroidBackupRestoresWithItsRows() async throws {
        let days = try await restored("android-v1")
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(days.first?.day, "2026-09-14")
        XCTAssertEqual(days.last?.day, "2026-10-25")
        XCTAssertEqual(days.last?.recovery, 72)
        XCTAssertEqual(days.last?.restingHr, 49)
    }

    func testAnAppleBackupRestoresWithItsRows() async throws {
        let days = try await restored("apple-v1")
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(days.first?.day, "2026-09-09")
        XCTAssertEqual(days.last?.day, "2026-10-20")
    }
}
