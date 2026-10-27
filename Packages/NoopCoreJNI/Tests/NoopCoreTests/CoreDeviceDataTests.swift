import XCTest
@testable import NoopCore
import WhoopStore

/// "Delete this device's data" and "Forget" on Android clear the core's copy first (parity plan 1.3), so the
/// journal the core now owns cannot outlive the source it was imported from.
final class CoreDeviceDataTests: XCTestCase {
    func testDeleteRemovesOnlyThatSourcesRows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("device-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ShadowSession.stop(); try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(ShadowSession.start(path: dir.appendingPathComponent("core.sqlite").path, deviceId: "qa-strap"), 0)
        let store = try XCTUnwrap(ShadowSession.storeAndPath?.0)
        let row = JournalEntry(day: "2026-10-20", question: "Any alcohol?", answeredYes: true, notes: nil)
        _ = try await store.upsertJournal([row], deviceId: "my-whoop")
        _ = try await store.upsertJournal([row], deviceId: "noop-journal")

        let missing = await CoreCall.run("device.deleteData", "{}")
        XCTAssertTrue(missing.contains("invalid"))
        let done = await CoreCall.run("device.deleteData", #"{"id":"my-whoop"}"#)
        XCTAssertTrue(done.contains("\"ok\":true"))
        let imported = try await store.journalEntries(deviceId: "my-whoop", from: "2026-01-01", to: "2026-12-31")
        let native = try await store.journalEntries(deviceId: "noop-journal", from: "2026-01-01", to: "2026-12-31")
        XCTAssertTrue(imported.isEmpty)
        XCTAssertEqual(native, [row])
    }
}
