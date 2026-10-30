import XCTest
import NoopCore
import StrandCore
import WhoopProtocol
import WhoopStore

/// The shadow session as the Android client drives it: a history offload's records and END, in order, banked in
/// the core's own store, with nothing sent back to the strap, and reported banked so the Kotlin ack can follow.
final class ShadowSessionTests: XCTestCase {
    /// Three real WHOOP 4.0 v25 history records (84 B, 1 Hz), the same ones the Backfiller tests replay.
    private let v25Records = [
        "aa50000c2f190013390000140d2b6a4075010068a2010032fdbcfd98fdd3fdccfd47ffb00366064f073e06c103d3016cffa2fc87fa2ffae5fdbe03140675060c0510012dff1bfec0018f3c500500010068dc8f44",
        "aa50000c2f190014390000150d2b6a487001003ab301008dfd6afdaffda9fdaffd68fddbfb0dfc09fd77fe89fe62febffec9fe91ff0bff81ff5fff3e00d600790078ff3dff4bff801d553c5005010000d7c016b3",
        "aa50000c2f190015390000160d2b6a586b01006d8f0100a3ff94ffc4ffbcffbeff22004a009400cb0048005d006b004400d700130115013301f20088001d0031ffd9fe5eff75ff0048933c50050001008bdf2c2c",
    ].map { hex in stride(from: 0, to: hex.count, by: 2).map {
        UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
    } }

    private func historyEnd(trim: UInt32) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
        return frameFromPayload(le32(1_700_000_000) + [0, 0] + le32(0) + le32(trim), type: 49, seq: 0, cmd: 2)
    }

    func testAnOffloadReplayedInOrderIsBankedInTheCoresStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { ShadowSession.stop(); try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(ShadowSession.start(path: dir.appendingPathComponent("core.sqlite").path, deviceId: "my-whoop"), 0)
        ShadowSession.send(.family(whoop5: false))
        ShadowSession.send(.offloadBegin(continuedAfterRows: false))
        for record in v25Records { ShadowSession.send(.offload(record)) }
        ShadowSession.send(.offload(historyEnd(trim: 70_476)))
        let expected = 3 + v25Records.count
        for _ in 0..<300 where ShadowSession.processedEvents < expected {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(ShadowSession.processedEvents, expected, "every event worked through, in order")
        XCTAssertGreaterThan(ShadowSession.tally.gravity, 0, "the END banked the records' motion")
        let store = try await WhoopStore(path: dir.appendingPathComponent("core.sqlite").path)
        let cursor = try await store.cursor("strap_trim")
        XCTAssertEqual(cursor, 70_476, "the core recorded the trim it would have acked; the ack itself is a no-op")

        // E-4: the chunk counts as banked for the Kotlin ack once persisted; an unknown chunk never does.
        let endFrame = historyEnd(trim: 70_476)
        let endData = await MainActor.run { Backfiller.endData(from: endFrame, family: .whoop4) }
        let end = try XCTUnwrap(endData)
        XCTAssertTrue(ShadowSession.awaitBanked(endData: end, timeout: 1))
        XCTAssertFalse(ShadowSession.awaitBanked(endData: [0, 1, 2, 3, 4, 5, 6, 7], timeout: 0.05))

        // The daily pass runs on the same store, in order after the offload, and leaves an answer.
        ShadowSession.send(.analyze(.init(age: 40, sex: "male", weightKg: 80, heightCm: 180, hrMaxOverride: 0),
                                    .standard))
        // A settings save must not refresh platform screens before the queued analysis publishes
        // its result. Check the snapshots on the same background thread as the blocking barrier,
        // before any additional await could let an unfinished worker catch up.
        ShadowSession.send(.resetTally)
        let completion: (Bool, String?, Int, ShadowSession.Tally) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let completed = ShadowSession.awaitQueuedEvents()
                continuation.resume(returning: (completed, ShadowSession.today,
                                                 ShadowSession.processedEvents, ShadowSession.tally))
            }
        }
        XCTAssertTrue(completion.0)
        XCTAssertNotNil(completion.1, "The analysis result is published before the barrier returns")
        XCTAssertGreaterThanOrEqual(completion.2, expected + 2,
                                    "Both analysis and the following reset have completed")
        XCTAssertEqual(completion.3.gravity, 0,
                       "A barrier also covers ordinary events queued after the analysis")
        XCTAssertEqual(completion.3.hr, 0)
    }

    /// A retired strap's nights stay in the screens' reads, and an in-process strap switch re-points the reader
    /// and the writers: the Room fallback reads every registered WHOOP, so the core must too.
    func testRegisteredStrapsStayInTheReadsAndASwitchFollowsTheActiveStrap() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            ShadowSession.stop()
            ShadowSession.setDevices(activeDeviceId: "", registeredWhoopIds: [])
            try? FileManager.default.removeItem(at: dir)
        }
        let path = dir.appendingPathComponent("core.sqlite").path
        XCTAssertEqual(ShadowSession.start(path: path, deviceId: "whoop-old"), 0)
        let store = try XCTUnwrap(ShadowSession.storeAndPath?.store)
        let night = CachedSleepSession(startTs: 1_700_000_000, endTs: 1_700_028_000, efficiency: 90,
                                       restingHr: 50, avgHrv: 60, stagesJSON: "[]")
        _ = try await store.upsertSleepSessions([night], deviceId: "whoop-old")

        // The wearer switched to a new strap; the old one stays registered (archived).
        ShadowSession.setDevices(activeDeviceId: "whoop-new", registeredWhoopIds: ["whoop-old", "whoop-new", "whoop-old"])
        let reader = try XCTUnwrap(ShadowSession.reader)
        XCTAssertEqual(reader.activeDeviceId, "whoop-new")
        XCTAssertEqual(reader.rawPhysiologyReadIds, ["whoop-new", "whoop-old", "my-whoop"])
        let nights = await reader.unionSleepSessions(from: 1_699_990_000, to: 1_700_100_000)
        XCTAssertEqual(nights.map(\.startTs), [1_700_000_000], "the retired strap's night is still read")

        // Without the registry the retired strap's night is gone, which is the bug this guards.
        ShadowSession.setDevices(activeDeviceId: "whoop-new", registeredWhoopIds: [])
        let bare = await ShadowSession.reader?.unionSleepSessions(from: 1_699_990_000, to: 1_700_100_000)
        XCTAssertEqual(bare?.count, 0)

        // The writers follow too: an offload after the switch is banked under the new strap's id.
        ShadowSession.send(.family(whoop5: false))
        ShadowSession.send(.offloadBegin(continuedAfterRows: false))
        for record in v25Records { ShadowSession.send(.offload(record)) }
        ShadowSession.send(.offload(historyEnd(trim: 70_476)))
        let completed: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: ShadowSession.awaitQueuedEvents()) }
        }
        XCTAssertTrue(completed)
        let newGravity = try await store.gravitySamples(deviceId: "whoop-new", from: 0, to: Int.max, limit: 10)
        let oldGravity = try await store.gravitySamples(deviceId: "whoop-old", from: 0, to: Int.max, limit: 10)
        XCTAssertFalse(newGravity.isEmpty, "frames after the switch belong to the new strap")
        XCTAssertTrue(oldGravity.isEmpty)
    }
}
