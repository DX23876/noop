import XCTest
@testable import NoopCore
import WhoopStore

/// The Android input lanes over the JSON door (parity plan 1.3): Room rows cross as column values, are adopted
/// once, mirrored afterwards, and a re-keyed strap takes its rows along.
final class CoreInputLanesTests: XCTestCase {
    func testRoomRowsCrossAdoptMirrorAndReKey() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lanes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ShadowSession.stop(); try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(ShadowSession.start(path: dir.appendingPathComponent("core.sqlite").path, deviceId: "qa-strap"), 0)
        let store = try XCTUnwrap(ShadowSession.storeAndPath?.0)

        let owned = await CoreCall.run("lanes.owned", "{}")
        XCTAssertTrue(owned.contains("\"owned\":false"))
        _ = await CoreCall.run("lanes.reset", "{}")
        let staged = await CoreCall.run("lanes.stage", #"""
            {"table":"appleDaily","rows":[{"deviceId":"health-connect","day":"2026-10-20","steps":8000,"activeKcal":410.5,"weightKg":null}]}
            """#)
        XCTAssertTrue(staged.contains("\"ok\":true"), staged)
        let committed = await CoreCall.run("lanes.commit", #"{"replace":false}"#)
        XCTAssertTrue(committed.contains("\"moved\":1"), committed)
        let days = try await store.appleDaily(deviceId: "health-connect", from: "2026-10-01", to: "2026-10-31")
        XCTAssertEqual(days.first?.steps, 8000)
        XCTAssertEqual(days.first?.activeKcal, 410.5)

        let put = await CoreCall.run("lanes.put", #"""
            {"table":"workout","rows":[{"deviceId":"old-ring","startTs":100,"endTs":200,"sport":"Running","source":"manual","energyKcal":300}]}
            """#)
        XCTAssertTrue(put.contains("\"ok\":true"), put)
        let rekey = await CoreCall.run("device.reKey", #"{"from":"old-ring","to":"oura-SERIAL"}"#)
        XCTAssertTrue(rekey.contains("\"ok\":true"), rekey)
        let moved = try await store.workouts(deviceId: "oura-SERIAL", from: 0, to: 1_000, limit: 10)
        XCTAssertEqual(moved.map(\.energyKcal), [300])

        let deleted = await CoreCall.run("lanes.delete", #"""
            {"table":"workout","equals":{"deviceId":"oura-SERIAL","startTs":100,"sport":"Running"}}
            """#)
        XCTAssertTrue(deleted.contains("\"removed\":1"), deleted)
        let unknown = await CoreCall.run("lanes.put", #"{"table":"hrSample","rows":[]}"#)
        XCTAssertTrue(unknown.contains("error"))
    }
}
