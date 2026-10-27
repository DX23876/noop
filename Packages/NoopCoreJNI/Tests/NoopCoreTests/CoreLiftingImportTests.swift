import XCTest
@testable import NoopCore
import WhoopStore

final class CoreLiftingImportTests: XCTestCase {
    func testAndroidOperationBanksFullHistoryAndRejectsInvalidInput() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lifting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ShadowSession.stop(); try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(ShadowSession.start(path: dir.appendingPathComponent("core.sqlite").path, deviceId: "qa-strap"), 0)
        let csv = """
        title,start_time,end_time,exercise_title,set_type,weight_kg,reps
        Synthetic import,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,normal,80,8
        """
        func args(_ contents: String, zone: String = "Europe/Berlin") throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: ["data": Data(contents.utf8).base64EncodedString(), "timeZone": zone]), encoding: .utf8)!
        }
        let output = await CoreCall.run("training.importLifting", try args(csv))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(document["sessions"] as? Int, 1)
        XCTAssertEqual(document["skipped"] as? Int, 0)
        let projection = try XCTUnwrap(document["workouts"] as? [[String: Any]])
        XCTAssertEqual(projection.count, 1)
        XCTAssertEqual(projection[0]["source"] as? String, "lifting")
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let fixture = root.appendingPathComponent("android/app/src/test/resources/training/lifting-import.json")
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" {
            try Data(output.utf8).write(to: fixture)
        }
        let pinned = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? NSDictionary
        XCTAssertEqual(document as NSDictionary, pinned)
        let store = try XCTUnwrap(ShadowSession.storeAndPath?.0)
        let workouts = try await store.strengthWorkouts(from: 0, to: Int.max)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts[0].exercises[0].sets[0].weightKg, 80)
        XCTAssertEqual(workouts[0].startTs, 1_780_329_600)
        let badZone = await CoreCall.run("training.importLifting", try args(csv, zone: "invalid/zone"))
        XCTAssertTrue(badZone.contains("invalidImport"))
        let malformed = await CoreCall.run("training.importLifting", try args("not a lifting export"))
        XCTAssertTrue(malformed.contains("noWorkouts"))
        let remaining = try await store.strengthWorkouts(from: 0, to: Int.max)
        XCTAssertEqual(remaining, workouts)
    }
}
