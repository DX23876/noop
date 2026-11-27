import XCTest
@testable import NoopCore
import WhoopStore

/// Android's Health Connect export asks the core which records changed (`health.planExports`), the ledger Apple's
/// `HealthSampleWriter` keeps for Apple Health. Until 2026-11-26 every pass rewrote about 190 records.
final class CoreHealthExportTests: XCTestCase {
    private struct Planned: Decodable {
        struct Version: Decodable { let id: String; let revision: Int; let needsSave: Bool }
        let versions: [Version]
    }

    private func plan(_ store: WhoopStore, _ items: [(String, String)]) async throws -> [Planned.Version] {
        let answer = await CoreHealthExport.plan(store: store, args: ["items": items.map { ["id": $0.0, "fingerprint": $0.1] }])
        return try JSONDecoder().decode(Planned.self, from: Data(answer.utf8)).versions
    }

    private func commit(_ store: WhoopStore, _ versions: [Planned.Version]) async {
        _ = await CoreHealthExport.commit(store: store, args: ["versions": versions.map { ["id": $0.id, "revision": $0.revision] }])
    }

    func testAnUnchangedRecordIsWrittenOnceAndAChangedOneReplacesIt() async throws {
        let store = try await WhoopStore.inMemory()
        let first = try await plan(store, [("noop-rhr-2026-11-25", "rhr|1|52"), ("noop-hrv-2026-11-25", "hrv|1|61.0")])
        XCTAssertEqual(first.map(\.id), ["noop-rhr-2026-11-25", "noop-hrv-2026-11-25"], "ids come back in order, unprefixed")
        XCTAssertTrue(first.allSatisfy(\.needsSave), "nothing was written yet")
        let nowSeconds = Int(Date().timeIntervalSince1970)
        XCTAssertTrue(first.allSatisfy { $0.revision >= nowSeconds - 2 && $0.revision < nowSeconds + 60 },
                      "revisions are in seconds, so an older build that stamps seconds still replaces them")
        await commit(store, first)

        let again = try await plan(store, [("noop-rhr-2026-11-25", "rhr|1|52"), ("noop-hrv-2026-11-25", "hrv|1|61.0")])
        XCTAssertFalse(again.contains(where: \.needsSave), "the same content is not written again")

        let changed = try await plan(store, [("noop-rhr-2026-11-25", "rhr|1|51"), ("noop-hrv-2026-11-25", "hrv|1|61.0")])
        XCTAssertEqual(changed.map(\.needsSave), [true, false])
        XCTAssertGreaterThan(changed[0].revision, first[0].revision, "Health Connect replaces only a higher version")
    }

    func testARecordHealthConnectNeverAcceptedIsOfferedAgain() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await plan(store, [("noop-spo2-2026-11-25", "spo2|1|96.0")])
        let retry = try await plan(store, [("noop-spo2-2026-11-25", "spo2|1|96.0")])
        XCTAssertEqual(retry.map(\.needsSave), [true], "an insert that failed leaves the record pending")
    }

    func testARetractedRecordIsWrittenAgainWhenItComesBack() async throws {
        let store = try await WhoopStore.inMemory()
        let night = [("noop-sleep-1795600000", "sleep|1795600000|1795630000")]
        await commit(store, try await plan(store, night))
        _ = await CoreHealthExport.invalidate(store: store, args: ["ids": ["noop-sleep-1795600000"]])
        let back = try await plan(store, night)
        XCTAssertEqual(back.map(\.needsSave), [true], "a night deleted from Health Connect is written again")
    }

    func testAndroidIdsNeverMeetApplesInTheSharedTable() async throws {
        let store = try await WhoopStore.inMemory()
        let apple = try await store.planHealthExports([(id: "noop-rhr-2026-11-25", fingerprint: "rhr|1|52")])
        try await store.commitHealthExports(apple)
        let android = try await plan(store, [("noop-rhr-2026-11-25", "rhr|1|52")])
        XCTAssertEqual(android.map(\.needsSave), [true], "the Apple Health row is a different record")
    }
}
