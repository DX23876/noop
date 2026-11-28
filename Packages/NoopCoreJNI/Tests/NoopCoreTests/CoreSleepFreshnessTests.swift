import XCTest
@testable import NoopCore

final class CoreSleepFreshnessTests: XCTestCase {
    func testTheCallStatesTheNoteForAMissingNight() throws {
        // 2026-11-28 10:00 UTC; no night ended today, a sync failed.
        let now = 1_795_860_000.0
        let json = CoreSleepFreshness.run(["now": now, "latestWakeTs": Int(now) - 2 * 86_400, "syncFailed": true])
        let note = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(note?["status"] as? String, "syncFailed")
        XCTAssertEqual(note?["title"] as? String, "Last night's sleep hasn't synced")
    }

    func testANightInHandNeedsNoNote() {
        XCTAssertNil(CoreSleepFreshness.note(nil, chunks: 0).status)
        XCTAssertEqual(CoreSleepFreshness.note(.syncing, chunks: 3).message, "3 chunks pulled")
        XCTAssertEqual(CoreSleepFreshness.note(.syncing, chunks: 0).message, "")
    }
}
