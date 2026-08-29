import XCTest
@testable import WhoopStore

/// `HypnogramCoverage` — the ratio that tells a well-formed-looking stage timeline from one that
/// describes only part of the night it claims.
final class HypnogramCoverageTests: XCTestCase {

    /// Segments tiling `[0, span)` in 30 s steps, `n` of them, starting at `from`.
    private func segs(_ ranges: [(Int, Int, String)]) -> String {
        "[" + ranges.map { "{\"start\":\($0.0),\"end\":\($0.1),\"stage\":\"\($0.2)\"}" }
            .joined(separator: ",") + "]"
    }

    // MARK: - the ratio itself

    func testFractionIsCoveredOverSpan() {
        XCTAssertEqual(HypnogramCoverage.fraction(coveredSeconds: 300, spanSeconds: 600)!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(HypnogramCoverage.fraction(coveredSeconds: 600, spanSeconds: 600)!, 1.0, accuracy: 1e-12)
    }

    /// Overlapping/overhanging segments would otherwise report more than a whole night. A completeness
    /// gate must read that as "complete", never manufacture a failure out of malformed input.
    func testFractionClampsAboveOne() {
        XCTAssertEqual(HypnogramCoverage.fraction(coveredSeconds: 900, spanSeconds: 600)!, 1.0, accuracy: 1e-12)
    }

    /// nil means "unknown, do not judge" — distinct from 0, which a caller comparing against
    /// `minCoverage` would read as a bad night.
    func testFractionNilWhenNothingToMeasure() {
        XCTAssertNil(HypnogramCoverage.fraction(coveredSeconds: 300, spanSeconds: 0))
        XCTAssertNil(HypnogramCoverage.fraction(coveredSeconds: 300, spanSeconds: -1))
        XCTAssertNil(HypnogramCoverage.fraction(coveredSeconds: 0, spanSeconds: 600))
    }

    // MARK: - from a stored payload

    func testTilingTimelineCoversItsSpan() {
        let json = segs([(0, 300, "light"), (300, 600, "deep")])
        XCTAssertEqual(HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: 600)!, 1.0, accuracy: 1e-12)
        XCTAssertFalse(HypnogramCoverage.isHoled(stagesJSON: json, spanSeconds: 600))
    }

    /// The shape this whole change exists for: a hypnogram assembled from records that arrived
    /// incomplete. Many segments, all real, spanning a night they only partly describe. The measured
    /// worst case was 140 minutes of segments across a 601-minute span.
    func testHoledTimelineIsDetected() {
        let json = segs([(0, 4200, "light"), (4200, 8400, "deep")])   // 140 min over a 601 min span
        let span = 601.0 * 60.0
        let f = HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: span)!
        XCTAssertEqual(f, 8400.0 / span, accuracy: 1e-12)
        XCTAssertLessThan(f, 0.24)
        XCTAssertTrue(HypnogramCoverage.isHoled(stagesJSON: json, spanSeconds: span))
    }

    /// A hole in the MIDDLE is the real failure mode (a page that never arrived), not a short tail.
    func testInteriorHoleCounts() {
        let json = segs([(0, 300, "light"), (900, 1200, "deep")])     // 600 s of 1200 s
        XCTAssertEqual(HypnogramCoverage.fraction(stagesJSON: json, spanSeconds: 1200)!, 0.5, accuracy: 1e-12)
    }

    func testThresholdBoundaryIsInclusive() {
        // exactly minCoverage is NOT holed; a hair under it is.
        let atGate = segs([(0, 950, "light")])
        let underGate = segs([(0, 949, "light")])
        XCTAssertFalse(HypnogramCoverage.isHoled(stagesJSON: atGate, spanSeconds: 1000))
        XCTAssertTrue(HypnogramCoverage.isHoled(stagesJSON: underGate, spanSeconds: 1000))
    }

    // MARK: - what must NOT be judged

    /// The imported minute-dict shape carries no timestamps, so coverage is unanswerable. It must come
    /// back nil (not 0), which is what keeps every WHOOP/Apple/Health-Connect import out of this gate.
    func testImportedMinuteDictIsUnmeasurable() {
        let dict = "{\"light\":300,\"deep\":100,\"rem\":80,\"awake\":40}"
        XCTAssertNil(HypnogramCoverage.fraction(stagesJSON: dict, spanSeconds: 3600))
        XCTAssertFalse(HypnogramCoverage.isHoled(stagesJSON: dict, spanSeconds: 3600))
    }

    func testEmptyAndMalformedAreUnmeasurable() {
        for payload in [nil, "", "   ", "[]", "not json"] as [String?] {
            XCTAssertNil(HypnogramCoverage.fraction(stagesJSON: payload, spanSeconds: 3600),
                         "payload \(String(describing: payload)) should be unmeasurable")
            XCTAssertFalse(HypnogramCoverage.isHoled(stagesJSON: payload, spanSeconds: 3600),
                           "an unmeasurable payload must never read as holed")
        }
    }

    /// Every guard built on this fails OPEN: unknown coverage keeps the previous behaviour rather than
    /// downgrading a night on no evidence.
    func testSessionOverloadUsesItsOwnSpan() {
        let holed = CachedSleepSession(startTs: 0, endTs: 1200, efficiency: nil, restingHr: nil,
                                       avgHrv: nil, stagesJSON: segs([(0, 300, "light")]))
        let whole = CachedSleepSession(startTs: 0, endTs: 1200, efficiency: nil, restingHr: nil,
                                       avgHrv: nil, stagesJSON: segs([(0, 1200, "light")]))
        let stageless = CachedSleepSession(startTs: 0, endTs: 1200, efficiency: nil, restingHr: nil,
                                          avgHrv: nil, stagesJSON: nil)
        XCTAssertTrue(HypnogramCoverage.isHoled(holed))
        XCTAssertFalse(HypnogramCoverage.isHoled(whole))
        XCTAssertFalse(HypnogramCoverage.isHoled(stageless))
    }
}
