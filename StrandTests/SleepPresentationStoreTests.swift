import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class SleepPresentationStoreTests: XCTestCase {
    private func session(_ start: Int, hours: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: start + hours * 3600,
                           efficiency: 90, restingHr: 52, avgHrv: 60,
                           stagesJSON: "{\"light\":\(hours * 60 - 40),\"deep\":20,\"rem\":20,\"awake\":0}")
    }

    func testTabAndHostedCardShareSelectedSplitNightMotionAndKeepHistory() async throws {
        let db = try await WhoopStore.inMemory()
        try await db.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) - 86400
        let first = session(midnight - 3600, hours: 3)
        let second = session(midnight + 2 * 3600 + 600, hours: 4)
        let old = session(midnight - 2 * 86400, hours: 7)
        _ = try await db.upsertSleepSessions([old, first, second], deviceId: "my-whoop")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(db)
        var motionReads: [[Int]] = []
        let store = SleepPresentationStore { _, blocks in
            motionReads.append(blocks.map(\.startTs))
            return [:]
        }
        let key = SleepPresentationRevision(repo: repo)
        async let tab = store.presentation(repo: repo, revision: key)
        async let hosted = store.model(repo: repo, revision: key)
        let (base, hostedModel) = try await (tab, hosted)
        let shown = try await store.night(offset: 0, presentation: base, repo: repo, revision: key)
        XCTAssertEqual(base.groups.count, 2)
        XCTAssertEqual(hostedModel?.night.session, shown?.session)
        XCTAssertEqual(motionReads.count, 1)
        XCTAssertEqual(Set(motionReads[0]), Set([first.startTs, second.startTs]))
        XCTAssertFalse(motionReads[0].contains(old.startTs))
        _ = try await store.night(offset: 1, presentation: base, repo: repo, revision: key)
        XCTAssertEqual(motionReads.count, 2)
        XCTAssertEqual(motionReads[1], [old.startTs])
    }

    func testSourceSwitchRejectsAnOldPresentation() async throws {
        let db = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(db)
        let store = SleepPresentationStore()
        let oldKey = SleepPresentationRevision(repo: repo)
        let old = try await store.presentation(repo: repo, revision: oldKey)
        repo.adoptActiveDeviceId("strap-other")
        do {
            _ = try await store.night(offset: 0, presentation: old, repo: repo, revision: oldKey)
            XCTFail("source switch must reject the previous snapshot")
        } catch is CancellationError { }
        let new = try await store.presentation(repo: repo, revision: SleepPresentationRevision(repo: repo))
        XCTAssertNil(new.model)
        XCTAssertTrue(new.groups.isEmpty)
    }

    func testCorrectedNightWithSameRowCountReplacesCachedModel() async throws {
        let db = try await WhoopStore.inMemory()
        try await db.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) - 86400
        let original = session(midnight, hours: 6)
        _ = try await db.upsertSleepSessions([original], deviceId: "my-whoop")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(db)
        await repo.refresh()
        let store = SleepPresentationStore { _, _ in [:] }
        let oldKey = SleepPresentationRevision(repo: repo)
        let old = try await store.model(repo: repo, revision: oldKey)
        let count = repo.sleeps.count
        let corrected = session(midnight, hours: 8)
        _ = try await db.upsertSleepSessions([corrected], deviceId: "my-whoop")
        await repo.refresh()
        let newKey = SleepPresentationRevision(repo: repo)
        let new = try await store.model(repo: repo, revision: newKey)
        XCTAssertEqual(repo.sleeps.count, count)
        XCTAssertNotEqual(oldKey, newKey)
        XCTAssertEqual(old?.night.session.endTs, original.endTs)
        XCTAssertEqual(new?.night.session.endTs, corrected.endTs)
    }
}
