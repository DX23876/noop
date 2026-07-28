import XCTest
@testable import StrandAnalytics

/// #550: the coverage pair encodes WHICH over-count a night has, and until now that reading rule lived
/// only in a comment — so triaging an "HRV reads ~2× high" report required knowing it. These pin the rule.
///
/// The real-capture vectors come from #803 (WHOOP 4.0, two consecutive nights), which is also the first
/// evidence either way on whether the same-second de-dup scoped in #550 would be sufficient. It would not.
final class RrCoverageVerdictTests: XCTestCase {

    /// A night whose beat-time fits the wall clock. #803's 2026-07-15.
    func testCleanNightIsPlausible() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 0.89, collapsed: 0.88), .plausible)
    }

    /// The night that prompted the report. #803's 2026-07-16: collapsing same-second duplicates drops it
    /// 2.54 → 1.99, which is still impossible — so the duplicates straddle second boundaries and a
    /// same-second de-dup would NOT fix it. This is the case #550 needs to know about.
    func testRealCrossSecondCaptureIsNotFixableBySameSecondDedup() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 2.54, collapsed: 1.99),
                       .crossSecondOverCount)
    }

    /// Over-covered, but the collapse brings it back in range — the extra beats share a timestamp.
    func testCollapseRecoveringRangeMeansSameSecond() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 1.60, collapsed: 1.02),
                       .sameSecondOverCount)
    }

    /// The ceiling is a rounding allowance, so exactly at it still reads as fitting; a hair over does not.
    func testCeilingIsInclusive() {
        let ceil = HRVAnalyzer.coveragePlausibleCeiling
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: ceil, collapsed: ceil), .plausible)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: ceil + 0.01, collapsed: 0.5),
                       .sameSecondOverCount)
    }

    /// `rrCoverage` returns 0 for a window it cannot measure (< 2 beats / zero span). Absence of evidence
    /// is not a clean night — calling it `plausible` would claim the capture was fine when nothing was
    /// measurable, which is exactly what this verdict exists to avoid.
    func testUnmeasurableWindowIsNotReportedAsClean() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 0, collapsed: 0), .unmeasurable)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: -1, collapsed: 0), .unmeasurable)
    }

    /// Parity guard. Every IEEE-754 comparison with NaN is false, so `<=` and `>` are not each other's
    /// inverse there — writing one platform with `<=` and the other with `>` made the twins disagree on a
    /// NaN coverage (Swift said plausible, Kotlin said sameSecondOverCount). Both now negate `>`.
    func testNonFiniteCoverageIsUnmeasurableOnBothPlatforms() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: .nan, collapsed: 0.5), .unmeasurable)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: .nan, collapsed: .nan), .unmeasurable)
    }

    /// The verdict is only ever a function of the pair, never of which is larger — a collapse can never
    /// exceed the raw coverage in practice, but the classifier must not depend on that holding.
    func testCollapsedAboveCoverageStillClassifiesOnCoverageFirst() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 0.5, collapsed: 9.9), .plausible)
    }
}
