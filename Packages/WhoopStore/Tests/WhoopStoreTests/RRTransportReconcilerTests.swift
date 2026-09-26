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

    func testLabelledWhoop4HistoryWinsOverStandardOnlyWhereItCovers() {
        let rows = [
            RRInterval(ts: 300, rrMs: 1_000, srcChannel: .whoop4Historical, transport: .whoopHistorical),
            rr(301, 1_002, .standardHeartRate),
            rr(330, 1_004, .standardHeartRate),
        ]
        let resolved = RRTransportReconciler.reconcile(rows)
        XCTAssertEqual(resolved.map(\.ts), [300, 330])
        XCTAssertEqual(resolved.map(\.srcChannel), [.whoop4Historical, nil])
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

    // MARK: - WHOOP 5 (#2117 fork policy)

    private func w5(_ ts: Int, _ value: Int, _ transport: RRTransport?, _ channel: RRSourceChannel? = nil) -> RRInterval {
        RRInterval(ts: ts, rrMs: value, srcChannel: channel, transport: transport)
    }

    /// The reported regression: rows banked before any provenance existed must survive a WHOOP 5 read
    /// untouched, or HRV and Charge go blank for every night recorded before the upgrade.
    func testWhoop5LegacyOnlyInputIsKept() {
        let rows = [w5(1, 800, nil), w5(2, 810, nil), w5(3, 820, nil)]
        XCTAssertEqual(RRTransportReconciler.reconcile(rows, whoop5: true), rows)
    }

    /// A labelled night after the upgrade replaces legacy beats only where it actually covers them.
    func testWhoop5LabelledBeatsDoNotBlankUncoveredLegacy() {
        let rows = [w5(100, 800, nil), w5(101, 900, nil, .whoop5Historical), w5(200, 810, nil)]
        let out = RRTransportReconciler.reconcile(rows, whoop5: true)
        XCTAssertEqual(out.map(\.ts), [101, 200])
    }

    /// Native history outranks standard 0x2A37 for the same beat, labelled or not; the reverse of the
    /// non-WHOOP-5 order, where the standard profile is the reference.
    func testWhoop5HistoryOutranksStandard() {
        let labelled = [w5(100, 1000, .standardHeartRate, .whoop5Standard), w5(101, 990, .whoopHistorical, .whoop5Historical)]
        XCTAssertEqual(RRTransportReconciler.reconcile(labelled, whoop5: true).map(\.ts), [101])
        let unlabelled = [w5(100, 977, .standardHeartRate), w5(101, 990, .whoopHistorical)]
        XCTAssertEqual(RRTransportReconciler.reconcile(unlabelled, whoop5: true).map(\.ts), [101])
        XCTAssertEqual(RRTransportReconciler.reconcile(unlabelled, whoop5: false).map(\.ts), [100])
    }

    /// An unlabelled WHOOP 5 standard beat was stored as `round(raw * 1000 / 1024)`; the read restores the
    /// strap's milliseconds to within 1 ms. A labelled standard beat (#2195) is already raw and untouched.
    func testWhoop5LegacyStandardUnitsAreRestoredOnRead() {
        for raw in [300, 612, 875, 1000, 1337, 2000] {
            let stored = Int((Double(raw) * 1000 / 1024).rounded())
            let out = RRTransportReconciler.reconcile([w5(100, stored, .standardHeartRate)], whoop5: true)
            XCTAssertLessThanOrEqual(abs(out[0].rrMs - raw), 1, "raw \(raw)")
        }
        let labelled = [w5(100, 1000, .standardHeartRate, .whoop5Standard)]
        XCTAssertEqual(RRTransportReconciler.reconcile(labelled, whoop5: true), labelled)
        let whoop4 = [w5(100, 977, .standardHeartRate)]
        XCTAssertEqual(RRTransportReconciler.reconcile(whoop4, whoop5: false), whoop4)
    }

    /// Stored rows are never rewritten: the unit restore is a read-time view.
    func testWhoop5ReadRestoresUnitsWithoutRewritingStorage() async throws {
        let store = try await WhoopStore.inMemory()
        // The registry seeds the canonical "my-whoop" row; confirm it as a WHOOP 5.
        try await store.registryWriter.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET model = '5.0 MG', brand = 'WHOOP' WHERE id = 'my-whoop'")
        }
        _ = try await store.insert(Streams(rr: [w5(100, 977, .standardHeartRate)]), deviceId: "my-whoop")
        let read = try await store.rrIntervals(deviceId: "my-whoop", from: 0, to: 200, limit: 10)
        XCTAssertEqual(read.map(\.rrMs), [1000])
        let stored = try await store.rrRowsWithChannelForTest(deviceId: "my-whoop")
        XCTAssertEqual(stored.count, 1)
    }
}
