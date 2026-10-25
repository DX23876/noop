import XCTest
import NoopCore
import WhoopProtocol
import WhoopStore

/// The shadow session as the Android client drives it: a history offload's records and END, in order, banked in
/// the core's own store, with nothing sent back to the strap.
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

        // The daily pass runs on the same store, in order after the offload, and leaves an answer.
        ShadowSession.send(.analyze(.init(age: 40, sex: "male", weightKg: 80, heightCm: 180, hrMaxOverride: 0)))
        for _ in 0..<500 where ShadowSession.today == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(ShadowSession.today)
    }
}
