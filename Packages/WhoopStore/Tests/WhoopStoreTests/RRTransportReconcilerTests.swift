import XCTest
import WhoopProtocol
@testable import WhoopStore

final class RRTransportReconcilerTests: XCTestCase {
    /// Segment 10 of the epoch-aligned five-minute grid: seconds 3000-3299.
    private let seg = 3_000
    private let segLength = RRTransportReconciler.segmentSeconds

    private func rr(_ ts: Int, _ value: Int = 1_000, _ transport: RRTransport?,
                    _ channel: RRSourceChannel? = nil) -> RRInterval {
        RRInterval(ts: ts, rrMs: value, srcChannel: channel, transport: transport)
    }

    /// One beat per second over `seconds`, its value a function of the second so a shifted copy of the same
    /// beats is recognisable.
    private func train(_ seconds: [Int], shift: Int = 0, _ transport: RRTransport?,
                       _ channel: RRSourceChannel? = nil) -> [RRInterval] {
        seconds.map { rr($0 + shift, 800 + ($0 % 97), transport, channel) }
    }

    private func sortedByTs(_ rows: [RRInterval]) -> [RRInterval] {
        rows.enumerated().sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }.map(\.element)
    }

    // MARK: - One path per segment

    /// The failure a per-beat radius cannot avoid: the standard-profile copy runs 6 s behind the history, and
    /// the history has a 10 s hole. A radius of 3 s let the standard beats in the middle of the hole through,
    /// and they are the copies of history beats just before it. A segment reads one path, so nothing leaks.
    func testDriftedStandardCopyIsNotSplicedIntoAHistoryGap() {
        let historySeconds = Array(seg..<(seg + segLength)).filter { !(seg + 100..<seg + 110).contains($0) }
        let history = train(historySeconds, .whoopHistorical, .whoop5Historical)
        let standard = train(Array(seg..<(seg + segLength - 6)), shift: 6, .standardHeartRate, .whoop5Standard)
        let out = RRTransportReconciler.reconcile(sortedByTs(history + standard), whoop5: true)
        XCTAssertEqual(out, history)
    }

    func testPartialHistoryYieldsToACompleteStandardTrain() {
        let history = train(Array(seg..<(seg + 120)), .whoopHistorical, .whoop4Historical)
        let standard = train(Array(seg..<(seg + segLength)), .standardHeartRate, .whoop4Standard)
        let out = RRTransportReconciler.reconcile(sortedByTs(history + standard))
        XCTAssertEqual(out, standard)
    }

    /// Two labelled paths never share a segment: the nearly complete history is read alone, with neither
    /// its gap nor its tail filled from the standard copy.
    func testNearlyCompleteHistoryWinsWithoutStandardBeats() {
        let historySeconds = Array(seg..<(seg + 250)).filter { !(seg + 100..<seg + 110).contains($0) }
        let history = train(historySeconds, .whoopHistorical, .whoop4Historical)
        let standard = train(Array(seg..<(seg + segLength)), .standardHeartRate, .whoop4Standard)
        let out = RRTransportReconciler.reconcile(sortedByTs(history + standard))
        XCTAssertEqual(out, history)
    }

    /// The same holds from the other side: a labelled path chosen first is joined only by rows without
    /// provenance, never by another labelled path.
    func testALabelledPathIsJoinedOnlyByUnlabelledRows() {
        let history = train(Array(seg..<(seg + 250)), .whoopHistorical, .whoop5Historical)
        let standardTail = train(Array((seg + 260)..<(seg + 280)), .standardHeartRate, .whoop5Standard)
        let legacyTail = train(Array((seg + 280)..<(seg + 300)), nil)
        let out = RRTransportReconciler.reconcile(history + standardTail + legacyTail, whoop5: true)
        XCTAssertEqual(out, history + legacyTail)
    }

    /// A path that stops inside a segment (the first labelled beats after an upgrade, an offload's edge)
    /// leaves the beats before it to the path that recorded them.
    func testLegacyBeatsBeforeALabelledStretchInTheSameSegmentAreKept() {
        let legacy = train(Array(seg..<(seg + 10)), nil)
        let labelled = train(Array((seg + 100)..<(seg + 110)), .whoopHistorical, .whoop5Historical)
        let out = RRTransportReconciler.reconcile(legacy + labelled, whoop5: true)
        XCTAssertEqual(out, legacy + labelled)
    }

    /// A path storing two rows per second does not make the history look incomplete beside it: occupancy
    /// counts seconds, not rows. Counted by rows, 250 history seconds would fall short of 600 standard rows.
    func testRepeatedBeatsDoNotInflateAPathsClaim() {
        let history = train(Array(seg..<(seg + 250)), .whoopHistorical)
        let standardSeconds = Array(seg..<(seg + segLength))
        let standard = train(standardSeconds, .standardHeartRate)
            + train(standardSeconds, .standardHeartRate).map { rr($0.ts, $0.rrMs + 1, .standardHeartRate) }
        let out = RRTransportReconciler.reconcile(sortedByTs(history + standard))
        XCTAssertEqual(out, history)
    }

    func testEachSegmentChoosesItsOwnPath() {
        let first = train(Array(seg..<(seg + segLength)), .whoopHistorical, .whoop5Historical)
            + train(Array(seg..<(seg + segLength)), .standardHeartRate, .whoop5Standard)
        let secondStart = seg + segLength
        let second = train(Array(secondStart..<(secondStart + segLength)), .standardHeartRate, .whoop5Standard)
        let out = RRTransportReconciler.reconcile(sortedByTs(first + second), whoop5: true)
        XCTAssertEqual(out.filter { $0.ts < secondStart }.map(\.srcChannel),
                       Array(repeating: .whoop5Historical, count: segLength))
        XCTAssertEqual(out.filter { $0.ts >= secondStart }.map(\.srcChannel),
                       Array(repeating: .whoop5Standard, count: segLength))
    }

    // MARK: - Paths and precedence

    /// A promotion relabels a stored standard row as history without rewriting its transport. The label
    /// names the path.
    func testALabelNamesThePathBeforeTheTransport() {
        XCTAssertEqual(RRTransportReconciler.path(rr(1, 800, .standardHeartRate, .whoop5Historical)), .history)
        XCTAssertEqual(RRTransportReconciler.path(rr(1, 800, .standardHeartRate, .whoop4Historical)), .history)
        XCTAssertEqual(RRTransportReconciler.path(rr(1, 800, nil, .whoop4Standard)), .standard)
        XCTAssertEqual(RRTransportReconciler.path(rr(1, 800, nil, .whoop5Realtime)), .realtime)
        XCTAssertEqual(RRTransportReconciler.path(rr(1, 800, .whoopHistorical)), .history)
        XCTAssertEqual(RRTransportReconciler.path(rr(1, 800, nil, .greenQuality)), .unknown)
        XCTAssertEqual(RRTransportReconciler.path(rr(1, 800, nil)), .unknown)
    }

    /// Only the owner family's labels name a path: a WHOOP 5 label on a WHOOP 4 read, or the reverse, is
    /// a stray tag and falls back to the row's transport.
    func testOnlyTheOwnersFamilyLabelsNameAPath() {
        XCTAssertEqual(RRTransportReconciler.path(rr(1, 800, nil, .whoop5Standard), whoop5: false), .unknown)
        XCTAssertEqual(RRTransportReconciler.path(rr(1, 800, nil, .whoop4Historical), whoop5: true), .unknown)
        XCTAssertEqual(RRTransportReconciler.path(rr(1, 800, .whoopHistorical, .whoop4Historical), whoop5: true),
                       .history)
        XCTAssertEqual(RRTransportReconciler.path(rr(1, 800, nil, .whoop5Standard), whoop5: true), .standard)
    }

    func testHistoryOutranksStandardWhichOutranksRealtimeOnEqualCoverage() {
        let seconds = Array(seg..<(seg + 60))
        let history = train(seconds, .whoopHistorical)
        let standard = train(seconds, .standardHeartRate).map { rr($0.ts, $0.rrMs + 3, .standardHeartRate) }
        let realtime = train(seconds, .whoopRealtime).map { rr($0.ts, $0.rrMs + 5, .whoopRealtime) }
        for whoop5 in [false, true] {
            XCTAssertEqual(RRTransportReconciler.reconcile(sortedByTs(history + standard + realtime),
                                                           whoop5: whoop5), history)
            XCTAssertEqual(RRTransportReconciler.reconcile(sortedByTs(standard + realtime),
                                                           whoop5: whoop5).map(\.transport),
                           Array(repeating: .standardHeartRate, count: seconds.count))
        }
    }

    /// Inside the chosen path the labelled copy of a beat still replaces an unlabelled one: both were
    /// stamped by the same clock.
    func testLabelledHistoryReplacesItsUnlabelledTwinInsideThePath() {
        let seconds = Array(seg..<(seg + 60))
        let labelled = train(seconds, .whoopHistorical, .whoop4Historical)
        let unlabelled = train(seconds, .whoopHistorical).map { rr($0.ts, $0.rrMs + 2, .whoopHistorical) }
        let out = RRTransportReconciler.reconcile(sortedByTs(labelled + unlabelled))
        XCTAssertEqual(out, labelled)
    }

    // MARK: - Rows without provenance

    func testLegacyOnlyInputIsByteIdentical() {
        let rows = [rr(1, 800, nil), rr(1, 810, nil), rr(2, 820, nil)]
        XCTAssertEqual(RRTransportReconciler.reconcile(rows), rows)
    }

    func testALabelledPathReplacesLegacyCopiesOfTheSameSeconds() {
        let seconds = Array(seg..<(seg + segLength))
        let legacy = train(seconds, nil)
        let labelled = train(seconds, .standardHeartRate, .whoop5Standard).map {
            rr($0.ts, $0.rrMs + 4, .standardHeartRate, .whoop5Standard)
        }
        let out = RRTransportReconciler.reconcile(sortedByTs(legacy + labelled), whoop5: true)
        XCTAssertEqual(out, labelled)
    }

    /// The first labelled night after an upgrade, or a partial offload, must not blank the segments it does
    /// not reach.
    func testLegacySegmentsNextToLabelledOnesAreKept() {
        let legacy = train(Array(seg..<(seg + segLength)), nil)
        let nextStart = seg + segLength
        let labelled = train(Array(nextStart..<(nextStart + segLength)), .whoopHistorical, .whoop5Historical)
        let out = RRTransportReconciler.reconcile(legacy + labelled, whoop5: true)
        XCTAssertEqual(out, legacy + labelled)
    }

    // MARK: - Store: upserts and window independence

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

    /// Three segments: complete history beside its standard copy, then a partial offload, then standard
    /// alone. Reading the night whole or in windows that cut across segment boundaries selects the same
    /// beats, and a capped read is a prefix of the whole read.
    func testWindowedAndCappedReadsSelectTheSameBeatsAsAWholeRead() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "strap", mac: nil, name: nil)
        let s1 = Array(seg..<(seg + segLength))
        let s2 = Array((seg + segLength)..<(seg + 2 * segLength))
        let s3 = Array((seg + 2 * segLength)..<(seg + 3 * segLength))
        var rows = train(s1, .whoopHistorical, .whoop4Historical)
            + train(s1, .standardHeartRate, .whoop4Standard).map {
                rr($0.ts, $0.rrMs + 3, .standardHeartRate, .whoop4Standard)
            }
        rows += train(Array(s2.prefix(100)), .whoopHistorical, .whoop4Historical)
        rows += train(s2 + s3, .standardHeartRate, .whoop4Standard).map {
            rr($0.ts, $0.rrMs + 3, .standardHeartRate, .whoop4Standard)
        }
        _ = try await store.insert(Streams(rr: sortedByTs(rows)), deviceId: "strap")

        let lo = seg, hi = seg + 3 * segLength - 1
        let whole = try await store.rrIntervals(deviceId: "strap", from: lo, to: hi, limit: Int.max)
        XCTAssertEqual(whole.filter { $0.ts < s2[0] }.map(\.srcChannel),
                       Array(repeating: .whoop4Historical, count: segLength))
        XCTAssertEqual(whole.filter { $0.ts >= s2[0] }.map(\.srcChannel),
                       Array(repeating: .whoop4Standard, count: 2 * segLength))

        var windowed: [RRInterval] = []
        var from = lo
        for width in [50, 400, 120, 1_000] {
            let to = min(from + width - 1, hi)
            windowed += try await store.rrIntervals(deviceId: "strap", from: from, to: to, limit: Int.max)
            from = to + 1
        }
        XCTAssertEqual(windowed, whole)

        for limit in [1, 10, 160, 250, 700] {
            let capped = try await store.rrIntervals(deviceId: "strap", from: lo, to: hi, limit: limit)
            XCTAssertEqual(capped, Array(whole.prefix(limit)), "limit \(limit)")
        }
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

    /// Native history outranks standard 0x2A37 for the same beat, labelled or not, on every WHOOP.
    func testWhoop5HistoryOutranksStandard() {
        let labelled = [w5(100, 1000, .standardHeartRate, .whoop5Standard), w5(101, 990, .whoopHistorical, .whoop5Historical)]
        XCTAssertEqual(RRTransportReconciler.reconcile(labelled, whoop5: true).map(\.ts), [101])
        let unlabelled = [w5(100, 977, .standardHeartRate), w5(101, 990, .whoopHistorical)]
        XCTAssertEqual(RRTransportReconciler.reconcile(unlabelled, whoop5: true).map(\.ts), [101])
        XCTAssertEqual(RRTransportReconciler.reconcile(unlabelled, whoop5: false).map(\.ts), [101])
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
