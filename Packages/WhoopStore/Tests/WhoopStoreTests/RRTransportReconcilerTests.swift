import XCTest
import WhoopProtocol
@testable import WhoopStore

final class RRTransportReconcilerTests: XCTestCase {
    private func rr(_ ts: Int, _ value: Int = 1_000, _ transport: RRTransport?) -> RRInterval {
        RRInterval(ts: ts, rrMs: value, transport: transport)
    }

    func testStandardTransportWinsOnlyInsideItsCoveredRun() {
        let rows = [
            rr(100, 990, nil),
            rr(101, 991, .whoopHistorical),
            rr(102, 992, .standardHeartRate),
            rr(103, 993, .whoopRealtime),
            rr(120, 994, nil),
        ]

        let resolved = RRTransportReconciler.reconcile(rows)
        XCTAssertEqual(resolved.map(\.ts), [102, 120])
        XCTAssertEqual(resolved.map(\.transport), [.standardHeartRate, nil])
    }

    func testHistoricalWinsOverProprietaryRealtimeWithoutStandardData() {
        let rows = [rr(200, 900, .whoopRealtime), rr(201, 910, .whoopHistorical)]
        XCTAssertEqual(RRTransportReconciler.reconcile(rows).map(\.transport), [.whoopHistorical])
    }

    func testLegacyOnlyInputIsByteIdentical() {
        let rows = [rr(1, 800, nil), rr(1, 810, nil), rr(2, 820, nil)]
        XCTAssertEqual(RRTransportReconciler.reconcile(rows), rows)
    }

    func testTaggedReinsertUpgradesLegacyProvenance() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "strap", mac: nil, name: nil)
        _ = try await store.insert(Streams(rr: [rr(100, 812, nil)]), deviceId: "strap")
        _ = try await store.insert(
            Streams(rr: [rr(100, 812, .whoopHistorical)]), deviceId: "strap")

        let read = try await store.rrIntervals(deviceId: "strap", from: 0, to: 200, limit: 10)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.transport, .whoopHistorical)
    }

    func testExactDuplicateKeepsThePreferredTransportInEitherInsertOrder() async throws {
        for transports in [[RRTransport.whoopRealtime, .whoopHistorical, .standardHeartRate],
                           [.standardHeartRate, .whoopHistorical, .whoopRealtime]] {
            let store = try await WhoopStore.inMemory()
            try await store.upsertDevice(id: "strap", mac: nil, name: nil)
            for transport in transports {
                _ = try await store.insert(
                    Streams(rr: [rr(100, 812, transport)]), deviceId: "strap")
            }

            let read = try await store.rrIntervals(deviceId: "strap", from: 0, to: 200, limit: 10)
            XCTAssertEqual(read.count, 1)
            XCTAssertEqual(read.first?.transport, .standardHeartRate)
        }
    }

    func testReadDropsOverlappingLegacyAndKeepsUncoveredLegacy() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "strap", mac: nil, name: nil)
        _ = try await store.insert(Streams(rr: [
            rr(100, 800, nil), rr(110, 810, nil), rr(100, 820, .standardHeartRate),
        ]), deviceId: "strap")

        let read = try await store.rrIntervals(deviceId: "strap", from: 0, to: 200, limit: 10)
        XCTAssertEqual(read.map(\.ts), [100, 110])
        XCTAssertEqual(read.map(\.transport), [.standardHeartRate, nil])
    }
}
