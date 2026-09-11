import XCTest
@testable import StrandAnalytics

/// Pins the personal step length that `movementMET` prices cadence with.
///
/// The point of this type is what it REFUSES to do: it will not average an outlier in, will not pull an
/// implausible reading to the boundary, and will not produce a figure from thin evidence. Most of these
/// tests are about those refusals, because the failure they prevent is silent — a wrong step length
/// does not crash, it just misprices every walk the wearer takes.
final class StrideLengthTests: XCTestCase {

    /// The ordinary case: several plausible readings collapse to their middle value.
    func testPlausibleReadingsCollapseToTheirMedian() {
        let estimate = StrideLength.personal(from: [0.70, 0.72, 0.74, 0.76, 0.78])
        XCTAssertEqual(estimate?.metersPerStep ?? 0, 0.74, accuracy: 1e-9)
        XCTAssertEqual(estimate?.sampleCount, 5)
    }

    /// Even counts average the two middle values, matching `AdaptiveExpenditureEngine` and
    /// `EnergyCalibrationEngine` on the same shape of data.
    func testAnEvenCountAveragesTheTwoMiddleValues() {
        let estimate = StrideLength.personal(from: [0.70, 0.72, 0.74, 0.76, 0.78, 0.80])
        XCTAssertEqual(estimate?.metersPerStep ?? 0, 0.75, accuracy: 1e-9)
    }

    /// Input order must not change the answer.
    func testTheAnswerDoesNotDependOnInputOrder() {
        let forward = StrideLength.personal(from: [0.68, 0.71, 0.74, 0.77, 0.90])
        let shuffled = StrideLength.personal(from: [0.90, 0.71, 0.77, 0.68, 0.74])
        XCTAssertEqual(forward, shuffled)
    }

    /// A single wild bout cannot drag the figure — the whole reason this is a median and not a mean.
    /// The mean of these readings is above 0.9; the median stays where the walking actually was.
    func testOneWildBoutCannotDragTheFigure() {
        let estimate = StrideLength.personal(from: [0.72, 0.73, 0.74, 0.75, 1.09])
        XCTAssertEqual(estimate?.metersPerStep ?? 0, 0.74, accuracy: 1e-9)
    }

    /// Out-of-range readings are DISCARDED, not clamped. Clamping would turn a nonsense sample into a
    /// confident wrong one sitting exactly on the boundary, where it would then look like evidence.
    func testOutOfRangeReadingsAreDiscardedRatherThanClamped() {
        // Two implausible readings on either side, five good ones in the middle.
        let estimate = StrideLength.personal(from: [0.05, 0.70, 0.72, 0.74, 0.76, 0.78, 3.4])
        XCTAssertEqual(estimate?.metersPerStep ?? 0, 0.74, accuracy: 1e-9)
        // Had they been clamped to 0.5 and 1.1 they would have counted, and the count would say 7.
        XCTAssertEqual(estimate?.sampleCount, 5)
    }

    /// Non-finite values are dropped before anything else looks at them.
    func testNonFiniteReadingsAreDropped() {
        let estimate = StrideLength.personal(from: [.nan, 0.70, 0.72, .infinity, 0.74, 0.76, 0.78])
        XCTAssertEqual(estimate?.metersPerStep ?? 0, 0.74, accuracy: 1e-9)
        XCTAssertEqual(estimate?.sampleCount, 5)
    }

    /// Thin evidence produces nothing at all, so the caller keeps the population average.
    func testThinEvidenceProducesNothing() {
        XCTAssertNil(StrideLength.personal(from: []))
        XCTAssertNil(StrideLength.personal(from: [0.74]))
        XCTAssertNil(StrideLength.personal(from: [0.72, 0.74, 0.76, 0.78]))
    }

    /// The minimum counts USABLE readings, not readings that arrived. Nine samples of which only four
    /// are plausible is still too thin.
    func testTheMinimumCountsUsableReadingsNotArrivedOnes() {
        XCTAssertNil(StrideLength.personal(from: [0.72, 0.74, 0.76, 0.78, 4.0, 4.1, 4.2, 4.3, 4.4]))
    }

    /// Exactly at the minimum, a figure is produced.
    func testExactlyAtTheMinimumAFigureIsProduced() {
        XCTAssertNotNil(StrideLength.personal(from: [0.70, 0.72, 0.74, 0.76, 0.78]))
    }

    /// The range boundaries themselves are inclusive — a reading exactly at the edge is plausible.
    func testRangeBoundariesAreInclusive() {
        let estimate = StrideLength.personal(from: [0.5, 0.5, 0.5, 1.1, 1.1, 1.1])
        XCTAssertEqual(estimate?.sampleCount, 6)
    }

    // MARK: - Choosing what to price a bucket with

    /// A measured figure is used as-is.
    func testAMeasuredFigureIsUsedAsIs() {
        XCTAssertEqual(StrideLength.metersPerStep(0.83), 0.83, accuracy: 1e-9)
    }

    /// Nothing measured means the population average — the behaviour the model had all along.
    func testNothingMeasuredMeansThePopulationAverage() {
        XCTAssertEqual(StrideLength.metersPerStep(nil), StrideLength.populationAverageM, accuracy: 1e-9)
        XCTAssertEqual(StrideLength.metersPerStep(nil), 0.75, accuracy: 1e-9)
    }

    /// A stored value that is somehow implausible falls back rather than being trusted. The database
    /// validates on write, but this path must not depend on that having happened.
    func testAnImplausibleStoredValueFallsBack() {
        XCTAssertEqual(StrideLength.metersPerStep(0.01), 0.75, accuracy: 1e-9)
        XCTAssertEqual(StrideLength.metersPerStep(2.9), 0.75, accuracy: 1e-9)
        XCTAssertEqual(StrideLength.metersPerStep(.nan), 0.75, accuracy: 1e-9)
    }

    // MARK: - Which step length applied on a given day?

    /// Five plausible readings on a day establish that day's own figure.
    func testADayWithEnoughReadingsUsesItsOwn() {
        let timeline = StepLengthTimeline(samplesByDay: [
            "2026-03-01": [0.70, 0.72, 0.74, 0.76, 0.78],
        ])
        XCTAssertEqual(timeline.metersPerStep(onDay: "2026-03-01"), 0.74, accuracy: 1e-9)
    }

    /// A quiet day inherits the last measurement rather than flickering back to the average, which
    /// would read as the wearer's stride changing when only the sampling did.
    func testAQuietDayInheritsTheLastMeasurement() {
        let timeline = StepLengthTimeline(samplesByDay: [
            "2026-03-01": [0.70, 0.72, 0.74, 0.76, 0.78],
            "2026-03-02": [0.73],   // too thin to establish anything
        ])
        XCTAssertEqual(timeline.metersPerStep(onDay: "2026-03-02"), 0.74, accuracy: 1e-9)
        XCTAssertEqual(timeline.metersPerStep(onDay: "2026-03-20"), 0.74, accuracy: 1e-9)
    }

    /// THE causality guarantee: a day is never priced with a measurement taken after it. Re-running the
    /// window must not rewrite an old day using something learned later.
    func testADayIsNeverPricedWithAFutureMeasurement() {
        let timeline = StepLengthTimeline(samplesByDay: [
            "2026-03-10": [0.85, 0.86, 0.87, 0.88, 0.89],
        ])
        XCTAssertNil(timeline.estimate(onDay: "2026-03-09"))
        XCTAssertEqual(timeline.metersPerStep(onDay: "2026-03-09"),
                       StrideLength.populationAverageM, accuracy: 1e-9)
        XCTAssertEqual(timeline.metersPerStep(onDay: "2026-03-10"), 0.87, accuracy: 1e-9)
    }

    /// Carry-forward is bounded: past the window the answer reverts to the documented average rather
    /// than asserting a year-old figure about this person.
    func testCarryForwardExpires() {
        let timeline = StepLengthTimeline(samplesByDay: [
            "2026-03-01": [0.70, 0.72, 0.74, 0.76, 0.78],
        ])
        XCTAssertEqual(timeline.metersPerStep(onDay: "2026-03-31"), 0.74, accuracy: 1e-9)
        XCTAssertNil(timeline.estimate(onDay: "2026-04-01"))
        XCTAssertEqual(timeline.metersPerStep(onDay: "2026-04-01"), 0.75, accuracy: 1e-9)
    }

    /// A newer measurement supersedes an older one from the day it exists, not before.
    func testANewerMeasurementSupersedesFromItsOwnDayOnward() {
        let timeline = StepLengthTimeline(samplesByDay: [
            "2026-03-01": [0.70, 0.70, 0.70, 0.70, 0.70],
            "2026-03-15": [0.90, 0.90, 0.90, 0.90, 0.90],
        ])
        XCTAssertEqual(timeline.metersPerStep(onDay: "2026-03-14"), 0.70, accuracy: 1e-9)
        XCTAssertEqual(timeline.metersPerStep(onDay: "2026-03-15"), 0.90, accuracy: 1e-9)
    }

    /// An empty timeline answers the population average for every day, so the caller never has to
    /// special-case "no Apple Health at all".
    func testAnEmptyTimelineAlwaysAnswersTheAverage() {
        let timeline = StepLengthTimeline(samplesByDay: [:])
        XCTAssertTrue(timeline.isEmpty)
        XCTAssertEqual(timeline.metersPerStep(onDay: "2026-03-01"), 0.75, accuracy: 1e-9)
    }

    /// The evidence count survives the day lookup, so provenance can say what the figure rests on.
    func testTheEvidenceCountSurvivesTheDayLookup() {
        let timeline = StepLengthTimeline(samplesByDay: [
            "2026-03-01": [0.70, 0.72, 0.74, 0.76, 0.78, 0.80, 4.0],
        ])
        XCTAssertEqual(timeline.estimate(onDay: "2026-03-05")?.sampleCount, 6)
    }
}
