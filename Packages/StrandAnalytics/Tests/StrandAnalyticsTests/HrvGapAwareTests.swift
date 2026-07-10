import XCTest
@testable import StrandAnalytics

/// Gap-aware RMSSD/pNN50 — the Swift twin of Android's `HrvGapAwareTest` (#204/#195).
///
/// When cleaning drops a beat (out-of-range or ectopic), its two neighbours become adjacent in the
/// cleaned list. Plain successive-difference RMSSD counts the difference ACROSS that splice as a real
/// beat-to-beat delta, and because RMSSD squares each delta one splice can dominate the window and bias
/// RMSSD high. These prove: no-drop data is unchanged; a middle drop no longer splices; the contiguity
/// flags mark exactly the splice; end-only drops leave every survivor contiguous; the boundary cases.
///
/// (Android's 7th case asserts the mismatched-length guard throws `IllegalArgumentException`; the Swift
/// guard is a `precondition`, which traps rather than throws and can't be caught in XCTest, so it's
/// intentionally not ported.)
final class HrvGapAwareTests: XCTestCase {

    // 1. No drops -> gap-aware equals plain, byte for byte.
    func testCleanSeriesIsUnchanged() {
        let rr = (0..<30).map { 800.0 + Double($0 % 5) * 20.0 } // 800..880, all in range, non-ectopic
        let clean = HRVAnalyzer.cleanRR(rr)
        XCTAssertEqual(clean.count, rr.count, "fixture must have no drops")

        let cleaned = HRVAnalyzer.cleanRRGapAware(rr)
        XCTAssertEqual(cleaned.nn, clean)
        XCTAssertTrue(cleaned.contiguous.dropFirst().allSatisfy { $0 }, "no drops -> every survivor contiguous")

        let plain = HRVAnalyzer.rmssdRaw(clean)!
        let gapAware = HRVAnalyzer.analyze(rawRR: rr).rmssd!
        XCTAssertEqual(gapAware, plain, accuracy: 1e-9)
    }

    // 2. A dropped middle beat must not splice its neighbours (the core fix).
    func testMidSeriesDropDoesNotSplice() {
        let rr = Array(repeating: 1000.0, count: 12) + [5000.0] + Array(repeating: 1100.0, count: 12)

        let result = HRVAnalyzer.analyze(rawRR: rr)
        XCTAssertEqual(result.nInput, 25)
        XCTAssertEqual(result.nClean, 24)
        XCTAssertNotNil(result.rmssd)
        XCTAssertEqual(result.rmssd!, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.pnn50!, 0.0, accuracy: 1e-9)

        // The plain (splicing) RMSSD over the SAME cleaned beats is clearly nonzero: proves divergence.
        let plainSpliced = HRVAnalyzer.rmssdRaw(HRVAnalyzer.cleanRR(rr))!
        XCTAssertGreaterThan(plainSpliced, 10.0, "plain RMSSD splices the 100 ms jump")
    }

    // 3. The contiguity flag is false only at the splice.
    func testContiguityFlagMarksTheSplice() {
        let rr = Array(repeating: 600.0, count: 3) + [5000.0] + Array(repeating: 600.0, count: 3)
        let cleaned = HRVAnalyzer.cleanRRGapAware(rr)
        XCTAssertEqual(cleaned.nn, HRVAnalyzer.cleanRR(rr))
        XCTAssertEqual(cleaned.nn, Array(repeating: 600.0, count: 6))
        XCTAssertEqual(cleaned.contiguous, [false, true, true, false, true, true])
    }

    // 4. Primitive: a spliced pair is excluded from the mean of squared differences.
    func testRmssdGapAwarePrimitiveSkipsSplice() {
        let nn = [500.0, 500.0, 1000.0, 1000.0]
        let contiguous = [false, true, false, true] // index 2 straddles a removed beat
        XCTAssertEqual(HRVAnalyzer.rmssdGapAware(nn, contiguous)!, 0.0, accuracy: 1e-9)
        XCTAssertGreaterThan(HRVAnalyzer.rmssdRaw(nn)!, 100.0)
        XCTAssertEqual(HRVAnalyzer.pnn50GapAware(nn, contiguous)!, 0.0, accuracy: 1e-9)
    }

    // 5. End-only drops keep every survivor contiguous (matches the #585 gate-test fixtures).
    func testEndDropsKeepAllContiguous() {
        let rr = Array(repeating: 800.0, count: 24) + Array(repeating: 100.0, count: 6) // 100 ms tail is out of range
        let cleaned = HRVAnalyzer.cleanRRGapAware(rr)
        XCTAssertEqual(cleaned.nn.count, 24)
        XCTAssertFalse(cleaned.contiguous[0])
        XCTAssertTrue(cleaned.contiguous.dropFirst().allSatisfy { $0 }, "no interior gap")
        XCTAssertEqual(HRVAnalyzer.rmssdGapAware(cleaned.nn, cleaned.contiguous), HRVAnalyzer.rmssdRaw(cleaned.nn))
    }

    // 6. Boundary cases: empty, all-dropped, sub-window series, single survivor, zero valid pairs.
    func testBoundaryCases() {
        let empty = HRVAnalyzer.cleanRRGapAware([])
        XCTAssertTrue(empty.nn.isEmpty && empty.contiguous.isEmpty)
        XCTAssertNil(HRVAnalyzer.rmssdGapAware(empty.nn, empty.contiguous))
        XCTAssertNil(HRVAnalyzer.pnn50GapAware(empty.nn, empty.contiguous))

        let allDropped = HRVAnalyzer.cleanRRGapAware(Array(repeating: 5000.0, count: 10)) // all out of range
        XCTAssertTrue(allDropped.nn.isEmpty)
        XCTAssertNil(HRVAnalyzer.rmssdGapAware(allDropped.nn, allDropped.contiguous))

        // Series shorter than the ectopic window is kept verbatim, matching cleanRR.
        let tiny = [800.0, 810.0]
        let tinyClean = HRVAnalyzer.cleanRRGapAware(tiny)
        XCTAssertEqual(tinyClean.nn, HRVAnalyzer.cleanRR(tiny))
        XCTAssertEqual(tinyClean.contiguous, [false, true])

        // One survivor between two dropped beats: no successive pair, nil RMSSD.
        let single = HRVAnalyzer.cleanRRGapAware([5000.0, 800.0, 5000.0])
        XCTAssertEqual(single.nn, [800.0])
        XCTAssertNil(HRVAnalyzer.rmssdGapAware(single.nn, single.contiguous))

        // Two survivors whose only pair straddles a gap: zero valid pairs, nil.
        XCTAssertNil(HRVAnalyzer.rmssdGapAware([600.0, 900.0], [false, false]))
        XCTAssertNil(HRVAnalyzer.pnn50GapAware([600.0, 900.0], [false, false]))
    }
}
