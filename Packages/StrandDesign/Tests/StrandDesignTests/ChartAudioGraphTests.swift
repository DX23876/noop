import XCTest
@testable import StrandDesign

/// The audio graph's axis maths, which is the part that can be silently wrong: an `AXChartDescriptor`
/// with a zero-width axis or out-of-order points still builds, still shows up in VoiceOver's rotor,
/// and simply plays nonsense — there is no crash and no warning to notice it by. These pin the two
/// invariants `AudioGraphPlan.series` exists to guarantee.
final class ChartAudioGraphTests: XCTestCase {

    private func point(_ x: Double, _ y: Double) -> AudioGraphPoint {
        AudioGraphPoint(x: x, y: y, label: "\(x)")
    }

    // MARK: Axis spans

    func testSpanCoversEveryValue() {
        let range = AudioGraphPlan.span([12, 4, 88, 30])
        XCTAssertEqual(range.lowerBound, 4)
        XCTAssertEqual(range.upperBound, 88)
    }

    func testFlatSeriesGetsAWidthRatherThanAZeroRange() {
        // A resting heart rate that held at 52 all week. min == max, and mapping a value into a
        // zero-width range is a divide-by-zero — every tone identical, or NaN.
        let range = AudioGraphPlan.span([52, 52, 52])
        XCTAssertLessThan(range.lowerBound, range.upperBound)
        XCTAssertTrue(range.contains(52))
    }

    func testFlatSeriesAtLargeMagnitudeGetsAProportionateWidth() {
        // A half-unit pad is invisible next to 1,000,000; the span scales with magnitude so the
        // padding is never lost to floating-point resolution.
        let range = AudioGraphPlan.span([1_000_000, 1_000_000])
        XCTAssertGreaterThan(range.upperBound - range.lowerBound, 1)
    }

    func testFlatSeriesAtZeroStillGetsAWidth() {
        // abs(0) * 0.01 is 0 — the floor is what saves this case.
        let range = AudioGraphPlan.span([0, 0])
        XCTAssertLessThan(range.lowerBound, range.upperBound)
    }

    func testEmptySeriesGetsAUsableRangeRatherThanCrashing() {
        let range = AudioGraphPlan.span([])
        XCTAssertLessThan(range.lowerBound, range.upperBound)
    }

    func testASingleReadingIsTreatedAsFlatNotAsEmpty() {
        let plan = AudioGraphPlan.series(title: "HRV", xLabel: "Date", yLabel: "HRV",
                                         points: [point(100, 42)])
        XCTAssertEqual(plan.points.count, 1)
        XCTAssertLessThan(plan.yRange.lowerBound, plan.yRange.upperBound)
        XCTAssertLessThan(plan.xRange.lowerBound, plan.xRange.upperBound)
    }

    // MARK: Ordering

    func testPointsAreSortedByX() {
        // VoiceOver steps the points in array order. An unsorted series scrubs back and forth in
        // time while announcing itself as a trend.
        let plan = AudioGraphPlan.series(title: "Charge", xLabel: "Date", yLabel: "Charge",
                                         points: [point(3, 30), point(1, 10), point(2, 20)])
        XCTAssertEqual(plan.points.map(\.x), [1, 2, 3])
        XCTAssertEqual(plan.points.map(\.y), [10, 20, 30])
    }

    func testAxisRangesFollowTheSortedData() {
        let plan = AudioGraphPlan.series(title: "Charge", xLabel: "Date", yLabel: "Charge",
                                         points: [point(3, 30), point(1, 10), point(2, 20)])
        XCTAssertEqual(plan.xRange, 1...3)
        XCTAssertEqual(plan.yRange, 10...30)
    }

    func testLabelsTravelWithTheirPointThroughTheSort() {
        // A label attached to the wrong reading is worse than no label: it states a number
        // confidently and wrongly.
        let plan = AudioGraphPlan.series(
            title: "Charge", xLabel: "Date", yLabel: "Charge",
            points: [AudioGraphPoint(x: 2, y: 20, label: "second"),
                     AudioGraphPoint(x: 1, y: 10, label: "first")]
        )
        XCTAssertEqual(plan.points.map(\.label), ["first", "second"])
    }

    // MARK: Empty

    func testAnEmptySeriesProducesAnEmptyButValidPlan() {
        let plan = AudioGraphPlan.series(title: "Charge", xLabel: "Date", yLabel: "Charge", points: [])
        XCTAssertTrue(plan.points.isEmpty)
        XCTAssertLessThan(plan.xRange.lowerBound, plan.xRange.upperBound)
        XCTAssertLessThan(plan.yRange.lowerBound, plan.yRange.upperBound)
    }
}

/// The dash ladder that carries a multi-series chart when colour is removed. The failure mode is
/// quiet: two series drawing the same pattern still renders, still looks deliberate, and simply
/// re-creates the ambiguity the ladder exists to remove.
final class ChartDifferentiationTests: XCTestCase {

    func testEveryPatternInTheLadderIsDistinct() {
        let patterns = ChartDifferentiation.dashPatterns
        for (i, a) in patterns.enumerated() {
            for (j, b) in patterns.enumerated() where i < j {
                XCTAssertNotEqual(a, b, "series \(i) and \(j) draw the same dash pattern")
            }
        }
    }

    func testTheLadderCoversEveryCompareSelectionSize() {
        // Compare permits 2–4 metrics at once; all four must be separable without wrapping.
        XCTAssertGreaterThanOrEqual(ChartDifferentiation.dashPatterns.count, 4)
        let first4 = (0..<4).map { ChartDifferentiation.dashPattern(seriesIndex: $0) }
        XCTAssertEqual(Set(first4.map(\.description)).count, 4)
    }

    func testTheFirstSeriesIsSolid() {
        // The default look must not change for a single-series chart, and an empty array is exactly
        // what StrokeStyle(dash:) reads as "solid".
        XCTAssertEqual(ChartDifferentiation.dashPattern(seriesIndex: 0), [])
    }

    func testAnIndexPastTheLadderWrapsRatherThanCrashing() {
        let count = ChartDifferentiation.dashPatterns.count
        XCTAssertEqual(ChartDifferentiation.dashPattern(seriesIndex: count),
                       ChartDifferentiation.dashPattern(seriesIndex: 0))
        XCTAssertEqual(ChartDifferentiation.dashPattern(seriesIndex: count + 2),
                       ChartDifferentiation.dashPattern(seriesIndex: 2))
    }

    func testANegativeIndexIsClampedRatherThanTrappingOnAModulo() {
        XCTAssertEqual(ChartDifferentiation.dashPattern(seriesIndex: -1),
                       ChartDifferentiation.dashPattern(seriesIndex: 1))
    }
}
