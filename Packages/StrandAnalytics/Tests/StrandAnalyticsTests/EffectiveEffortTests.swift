import XCTest
@testable import StrandAnalytics

/// #1001 — the single Effort figure every read-out on Today resolves through.
///
/// The bug: Effort was resolved independently in three places. Only the hero ring knew about the live
/// in-progress recompute; the Key Metrics tile and the HR chart's edge badge read the stored daily row,
/// which is rewritten only when the heavy daily pass runs. On a morning with a real HR climb the ring
/// showed 2.3 while the other two still showed 0.5.
///
/// These pin the resolution rule itself, and in particular the MAX — which is not a tie-break but the
/// never-drop floor from #489/#506, where a sparse-HR live under-read replaced a real 38.3 with 0.
final class EffectiveEffortTests: XCTestCase {

    /// The reported case: a live value ahead of a stale row wins, so every read-out moves together.
    func testLiveAheadOfAStaleRowWins() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 2.3, stored: 0.5)!, 2.3, accuracy: 1e-9)
    }

    /// The #489/#506 floor: a live UNDER-read must never pull a read-out below what today already earned.
    func testAStoredValueFloorsALiveUnderRead() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 0.0, stored: 38.3)!, 38.3, accuracy: 1e-9)
    }

    /// Past days carry no live value and use the row unchanged.
    func testNoLiveValueUsesTheStoredRow() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: nil, stored: 12.5)!, 12.5, accuracy: 1e-9)
    }

    /// Before the day has enough HR to score there is no row yet, so the live value stands alone.
    func testNoStoredRowUsesTheLiveValue() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 4.0, stored: nil)!, 4.0, accuracy: 1e-9)
    }

    /// Neither source is "No Data" — the read-outs must not invent a zero.
    func testNeitherSourceIsNil() {
        XCTAssertNil(StrainScorer.effectiveEffort(live: nil, stored: nil))
    }

    /// A genuine zero is a value, not an absence: a still day scores 0 and must render as 0, not "—".
    func testAGenuineZeroIsKept() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 0.0, stored: 0.0)!, 0.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.effectiveEffort(live: nil, stored: 0.0)!, 0.0, accuracy: 1e-9)
    }

    /// Equal sources are stable — resolving twice cannot make a read-out flicker.
    func testEqualSourcesResolveToThatValue() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 7.25, stored: 7.25)!, 7.25, accuracy: 1e-9)
    }

    /// #37: when both sources are zero, every sign pairing has the canonical positive-zero bits.
    func testBothPresentZerosCanonicalizePositiveZero() {
        let cases: [(label: String, live: Double, stored: Double)] = [
            ("positive/positive", 0.0, 0.0),
            ("positive/negative", 0.0, -0.0),
            ("negative/positive", -0.0, 0.0),
            ("negative/negative", -0.0, -0.0),
        ]

        for testCase in cases {
            let result = StrainScorer.effectiveEffort(live: testCase.live, stored: testCase.stored)!
            XCTAssertEqual(result.bitPattern, 0.0.bitPattern, testCase.label)
        }
    }

    /// A missing source is passthrough, including its exact signed-zero and NaN representation.
    func testSingleSourcePassesThroughBitForBit() {
        let values = [
            0.0,
            -0.0,
            7.25,
            -7.25,
            Double.infinity,
            -Double.infinity,
            Double(bitPattern: 0x7ff8_0000_0000_0042),
        ]

        for value in values {
            XCTAssertEqual(StrainScorer.effectiveEffort(live: value, stored: nil)!.bitPattern,
                           value.bitPattern)
            XCTAssertEqual(StrainScorer.effectiveEffort(live: nil, stored: value)!.bitPattern,
                           value.bitPattern)
        }
    }

    /// The zero canonicalization must not broaden into a replacement for Swift's MAX semantics.
    func testBothPresentNonzeroAndNaNBehaviorIsUnchanged() {
        let nanA = Double(bitPattern: 0x7ff8_0000_0000_0042)
        let nanB = Double(bitPattern: 0x7ff8_0000_0000_0024)
        let cases: [(live: Double, stored: Double, expected: Double)] = [
            (2.3, 0.5, 2.3),
            (7.25, 7.25, 7.25),
            (Double.infinity, 12.0, Double.infinity),
            (12.0, Double.infinity, Double.infinity),
            (-Double.infinity, -Double.infinity, -Double.infinity),
            (nanA, 1.0, nanA),
            (1.0, nanA, 1.0),
            (nanA, nanB, nanA),
            (nanB, nanA, nanB),
        ]

        for testCase in cases {
            let result = StrainScorer.effectiveEffort(live: testCase.live, stored: testCase.stored)!
            XCTAssertEqual(result.bitPattern, testCase.expected.bitPattern)
        }
    }
}
