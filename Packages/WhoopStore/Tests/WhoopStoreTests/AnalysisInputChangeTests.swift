import XCTest
import WhoopProtocol
@testable import WhoopStore

/// `analysisInputChange(after:)` answers "where did scoring inputs move since this write sequence value",
/// which the energy model uses to re-price only from the first changed day. A false `.none` would leave a
/// changed day priced on stale inputs, so each case pins the conservative side.
final class AnalysisInputChangeTests: XCTestCase {

    private let day = 86_400

    func testNothingWrittenAfterTheRevisionIsNone() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "whoop-1", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 10 * day + 100, bpm: 60)]), deviceId: "whoop-1")
        let seq = try await store.sensorWriteSeq()
        let change = try await store.analysisInputChange(after: seq)
        XCTAssertEqual(change, .none)
    }

    func testTheEarliestChangedDayIsReported() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "whoop-1", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 5 * day + 100, bpm: 60)]), deviceId: "whoop-1")
        let seq = try await store.sensorWriteSeq()
        _ = try await store.insert(Streams(hr: [HRSample(ts: 12 * day + 50, bpm: 61)]), deviceId: "whoop-1")
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 11 * day + 70, rrMs: 800)]), deviceId: "whoop-1")
        let change = try await store.analysisInputChange(after: seq)
        XCTAssertEqual(change, .since(utcDayStart: 11 * day))
    }

    /// Any device counts: the energy model reads the union of the wearer's sources.
    func testAChangeUnderAnotherDeviceCounts() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "whoop-1", mac: nil, name: nil)
        try await store.upsertDevice(id: "whoop-2", mac: nil, name: nil)
        let seq = try await store.sensorWriteSeq()
        _ = try await store.insert(Streams(hr: [HRSample(ts: 3 * day + 1, bpm: 60)]), deviceId: "whoop-2")
        let change = try await store.analysisInputChange(after: seq)
        XCTAssertEqual(change, .since(utcDayStart: 3 * day))
    }

    /// A device-wide invalidation cannot name its days, so the caller must treat everything as changed.
    func testADeviceWideInvalidationIsEverything() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "whoop-1", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 4 * day, bpm: 60)]), deviceId: "whoop-1")
        let seq = try await store.sensorWriteSeq()
        try await store.markAnalysisDeviceChangedForTest(deviceId: "whoop-1")
        let change = try await store.analysisInputChange(after: seq)
        XCTAssertEqual(change, .everything)
    }
}
