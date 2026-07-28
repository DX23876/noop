import XCTest
@testable import WhoopProtocol

/// #520: `dynamic_acceleration@41` has been decoded on both platforms since the v18 layout was mapped,
/// and nothing has ever consumed it — so there is no evidence on whether it is a usable stillness signal
/// or redundant against the gravity deltas `SleepStager` already derives. These pin the diagnostic that
/// collects that evidence: a summary, not a stream, logged once per offload session.
///
/// The Kotlin twin is `DynAccelDiagTest.kt`; both must fold in the same order and format the same bytes.
final class DynAccelDiagTests: XCTestCase {

    private let thr = dynAccelStillThresholdG   // 0.01 g, mirroring SleepStager.gravityStillThresholdG

    /// Nothing arrived: every derived value is nil and the log line is suppressed, so a WHOOP 4.0 (which
    /// never emits the field) or a caught-up session stays quiet rather than logging an empty summary.
    func testEmptyDiagIsSilent() {
        let d = Streams.DynAccelDiag()
        XCTAssertEqual(d.count, 0)
        XCTAssertNil(d.mean)
        XCTAssertNil(d.stillFraction)
        XCTAssertNil(d.min)
        XCTAssertNil(d.max)
        XCTAssertNil(d.logLine(threshold: thr))
    }

    /// The real f32@41 values from the six captured v18 frames — three of the six fall under the 0.01 g cut,
    /// so this pins the arithmetic against numbers that actually came off a strap rather than round ones.
    func testFoldsRealOracleValues() {
        var d = Streams.DynAccelDiag()
        for g in [0.009160, 0.010708, 0.005963, 0.014449, 0.032788, 0.008421] {
            d.add(g, threshold: thr)
        }
        XCTAssertEqual(d.count, 6)
        // Under 0.01 g: 0.009160, 0.005963, 0.008421.
        XCTAssertEqual(d.still, 3)
        XCTAssertEqual(d.stillFraction ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(d.min ?? 0, 0.005963, accuracy: 1e-12)
        XCTAssertEqual(d.max ?? 0, 0.032788, accuracy: 1e-12)
        XCTAssertEqual(d.mean ?? 0, 0.081489 / 6, accuracy: 1e-9)
    }

    /// The threshold is a strict `<`, so a value sitting exactly on it is NOT still — matching the stager's
    /// own `<`. Worth pinning because the cut is borrowed from the stager as a reference point, and a
    /// boundary that differed would add a second discrepancy on top of the one that already exists (the
    /// stager thresholds a delta, this an absolute magnitude).
    func testThresholdIsExclusive() {
        var d = Streams.DynAccelDiag()
        d.add(thr, threshold: thr)
        XCTAssertEqual(d.still, 0, "a value exactly at the threshold is not still")
        d.add(thr - 1e-9, threshold: thr)
        XCTAssertEqual(d.still, 1)
    }

    /// A non-finite value is dropped entirely rather than counted or folded into the sum — one NaN would
    /// otherwise poison mean/min/max for the whole session and make the diagnostic unreadable.
    func testNonFiniteValuesAreIgnored() {
        var d = Streams.DynAccelDiag()
        d.add(0.02, threshold: thr)
        d.add(.nan, threshold: thr)
        d.add(.infinity, threshold: thr)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.mean ?? 0, 0.02, accuracy: 1e-12)
        XCTAssertEqual(d.max ?? 0, 0.02, accuracy: 1e-12)
    }

    /// Merging is what makes the session figure meaningful: a chunk is an arbitrary slice of an offload, so
    /// the still-fraction only means anything once every chunk is folded together.
    func testMergeCombinesChunks() {
        var a = Streams.DynAccelDiag()
        a.add(0.004, threshold: thr)
        a.add(0.006, threshold: thr)
        var b = Streams.DynAccelDiag()
        b.add(0.500, threshold: thr)
        a.merge(b)
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a.still, 2)
        XCTAssertEqual(a.min ?? 0, 0.004, accuracy: 1e-12)
        XCTAssertEqual(a.max ?? 0, 0.500, accuracy: 1e-12)
        XCTAssertEqual(a.mean ?? 0, 0.510 / 3, accuracy: 1e-12)
    }

    /// Merging an empty diag must not disturb the accumulator — a console-only chunk is common mid-offload.
    func testMergingEmptyIsNoOp() {
        var a = Streams.DynAccelDiag()
        a.add(0.02, threshold: thr)
        let before = a
        a.merge(Streams.DynAccelDiag())
        XCTAssertEqual(a, before)
    }

    /// Merging INTO an empty accumulator has to adopt the other side's min/max rather than leaving them nil
    /// — the session accumulator starts empty, so this is the first merge of every session.
    func testMergeIntoEmptyAdoptsBounds() {
        var a = Streams.DynAccelDiag()
        var b = Streams.DynAccelDiag()
        b.add(0.03, threshold: thr)
        b.add(0.07, threshold: thr)
        a.merge(b)
        XCTAssertEqual(a, b)
    }

    /// The log line is the deliverable — the byte-identical contract with Kotlin. Pinned exactly so a
    /// format drift on either platform fails rather than silently producing two different corpora.
    func testLogLineFormat() {
        var d = Streams.DynAccelDiag()
        d.add(0.004, threshold: thr)
        d.add(0.006, threshold: thr)
        d.add(2.310, threshold: thr)
        XCTAssertEqual(
            d.logLine(threshold: thr),
            "Backfill: dynaccel n=3 still=67% mean=773mg range=4..2310mg "
            + "(thr 10mg) — diagnostic only, not stored or scored (#520)")
    }

    /// The line renders integers rather than `%.3f` because the two platforms round ties differently: C
    /// (Swift) is half-to-EVEN, Java (Kotlin) is HALF_UP, so `%.3f` of 0.0625 g is 0.062 on one and 0.063
    /// on the other — and 0.0625 is exactly representable in the f32 the strap sends, so it is reachable.
    /// These are the tie values; `mg`/`pct` must round them half-AWAY-from-zero, which is the one rule both
    /// languages' rounding functions agree on for non-negative input.
    func testTiesRoundAwayFromZeroNotPrintfStyle() {
        XCTAssertEqual(Streams.DynAccelDiag.mg(0.0625), 63, "62.5 mg must round up, not to even")
        XCTAssertEqual(Streams.DynAccelDiag.mg(0.0135), 14)
        XCTAssertEqual(Streams.DynAccelDiag.pct(0.665), 67, "66.5% must round up, not to even")
        XCTAssertEqual(Streams.DynAccelDiag.pct(0.005), 1, "0.5% must round up, not to even")
    }

    /// `extractHistoricalStreams` must actually populate the diag off a real frame, not just expose the
    /// type. Uses the same captured worn frame the oracle pins, whose f32@41 is 0.009160 g.
    func testExtractionPopulatesDiagFromARealFrame() throws {
        let hex = try realWornV18Hex()
        let parsed = parseFrame(hexToBytes(hex), family: .whoop5)
        let out = extractHistoricalStreams([parsed], deviceClockRef: 0, wallClockRef: 0)
        XCTAssertEqual(out.dynAccel.count, 1, "the v18 path did not fold dynamic_acceleration")
        XCTAssertEqual(out.dynAccel.max ?? 0, 0.009160, accuracy: 1e-5)
        XCTAssertEqual(out.dynAccel.still, 1, "0.00916 g is under the 0.01 g stillness cut")
    }

    /// Local hex decoder — every other suite in this target keeps its own file-private copy rather than
    /// widening a shared test helper, so this follows the same convention.
    private func hexToBytes(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var idx = s.startIndex
        while idx < s.endIndex, let next = s.index(idx, offsetBy: 2, limitedBy: s.endIndex) {
            out.append(UInt8(s[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        return out
    }

    /// Pull the captured frame out of the shared decoder oracle rather than re-pasting bytes, so this test
    /// and the cross-platform oracle can never disagree about what the frame is.
    private func realWornV18Hex() throws -> String {
        struct Oracle: Decodable {
            struct Frame: Decodable { let name: String; let hex: String }
            let frames: [Frame]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "decoder_oracle", withExtension: "json"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        return try XCTUnwrap(oracle.frames.first { $0.name == "whoop5_v18_real_worn" }?.hex)
    }
}
