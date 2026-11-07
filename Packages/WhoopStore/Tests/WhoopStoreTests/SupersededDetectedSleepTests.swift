import XCTest
@testable import WhoopStore

/// AI-34: a night detected again with a moved onset is written as a new row (rows are keyed by onset), so the
/// old row of an earlier, partial pass must go, or the two overlapping blocks read as a nap plus a short main
/// sleep. The shape is the owner's night of 3 to 4 November 2026: an old 00:51–02:57 row beside the current
/// 02:32–06:09 one, and an old 21:18–22:27 row beside the current 21:58–23:27 one.
final class SupersededDetectedSleepTests: XCTestCase {

    private let computed = "my-whoop-noop"
    private let imported = "my-whoop"

    private func session(_ start: Int, _ end: Int, edited: Bool = false) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9, restingHr: 50, avgHrv: 60,
                           stagesJSON: "[]", userEdited: edited)
    }

    private func starts(_ store: WhoopStore, _ deviceId: String) async throws -> [Int] {
        try await store.sleepSessions(deviceId: deviceId, from: 0, to: 100_000, limit: 100).map(\.startTs).sorted()
    }

    func testOverlappingOldRowWithAnotherOnsetIsRemoved() async throws {
        let store = try await WhoopStore.inMemory()
        // Minutes of the night as seconds stand-ins: old 21:18–22:27 and 00:51–02:57 (+24 h), current
        // 21:58–23:27 and 02:32–06:09 (+24 h).
        try await store.upsertSleepSessions([session(1_278, 1_347), session(1_491, 1_617)], deviceId: computed)
        let current = [session(1_318, 1_407), session(1_592, 1_809)]
        try await store.upsertSleepSessions(current, deviceId: computed)

        let removed = try await store.deleteSupersededDetectedSleep(deviceId: computed, keeping: current)

        XCTAssertEqual(removed, 2)
        let left = try await starts(store, computed)
        XCTAssertEqual(left, [1_318, 1_592])
    }

    func testRowWithTheSameOnsetAndRowsThatDoNotOverlapStay() async throws {
        let store = try await WhoopStore.inMemory()
        // An earlier night far away, and the current night's own row (same onset, updated in place).
        try await store.upsertSleepSessions([session(100, 900), session(5_000, 6_000)], deviceId: computed)
        let current = [session(5_000, 8_000)]
        try await store.upsertSleepSessions(current, deviceId: computed)

        let removed = try await store.deleteSupersededDetectedSleep(deviceId: computed, keeping: current)

        XCTAssertEqual(removed, 0)
        let left = try await starts(store, computed)
        XCTAssertEqual(left, [100, 5_000])
    }

    func testEditedRowsAndOtherNamespacesAreNeverRemoved() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSleepSessions([session(1_000, 4_000, edited: true)], deviceId: computed)
        try await store.upsertSleepSessions([session(1_500, 4_500)], deviceId: imported)
        let current = [session(2_000, 6_000)]
        try await store.upsertSleepSessions(current, deviceId: computed)

        let removed = try await store.deleteSupersededDetectedSleep(deviceId: computed, keeping: current)
        let removedImported = try await store.deleteSupersededDetectedSleep(deviceId: imported, keeping: current)

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(removedImported, 0)
        let leftComputed = try await starts(store, computed)
        let leftImported = try await starts(store, imported)
        XCTAssertEqual(leftComputed, [1_000, 2_000])
        XCTAssertEqual(leftImported, [1_500])
    }
}
