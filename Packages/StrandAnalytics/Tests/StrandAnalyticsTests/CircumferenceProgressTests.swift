import XCTest
@testable import StrandAnalytics

/// Pins the "did this grow or shrink" comparison — the question a tape measurement is taken to answer.
final class CircumferenceProgressTests: XCTestCase {

    private func reading(_ day: String, _ value: Double) -> BodyReading {
        BodyReading(day: day, takenAt: 0, value: value, source: "manual")
    }

    /// Weekly readings with a steady climb, as a bulking arm would produce.
    private let growing = [
        ("2026-08-02", 36.0), ("2026-08-09", 36.2), ("2026-08-16", 36.3),
        ("2026-08-23", 36.6), ("2026-08-30", 36.8), ("2026-09-06", 37.1),
    ]

    private var growingSeries: [BodyReading] {
        growing.map { reading($0.0, $0.1) }
    }

    /// The plain case: three weeks back, and the arm is bigger.
    func testAGrowingSiteReportsItsGrowth() throws {
        let change = try XCTUnwrap(CircumferenceProgress.change(
            key: "biceps_l", readings: growingSeries, from: "2026-08-16", to: "2026-09-06"))
        XCTAssertEqual(change.fromValue, 36.3, accuracy: 1e-9)
        XCTAssertEqual(change.toValue, 37.1, accuracy: 1e-9)
        XCTAssertEqual(change.deltaCm, 0.8, accuracy: 1e-9)
        XCTAssertEqual(change.fromDay, "2026-08-16")
    }

    /// A shrinking site reports a negative change — the cutting case.
    func testAShrinkingSiteReportsANegativeChange() throws {
        let waist = [("2026-08-02", 88.0), ("2026-08-16", 86.4), ("2026-09-06", 83.3)]
            .map { reading($0.0, $0.1) }
        let change = try XCTUnwrap(CircumferenceProgress.change(
            key: "waist", readings: waist, from: "2026-08-02", to: "2026-09-06"))
        XCTAssertEqual(change.deltaCm, -4.7, accuracy: 1e-9)
        XCTAssertTrue(change.exceedsTypicalStep)
    }

    /// THE honesty rule: a reference reading far from the requested point would make a long slow change
    /// look like a fast recent one, so the comparison is refused instead.
    func testAStaleReferenceIsRefusedRatherThanReachedFor() {
        let sparse = [reading("2026-05-01", 36.0), reading("2026-09-06", 37.1)]
        // Asking for "three weeks ago" resolves to a reading from May — four months adrift.
        XCTAssertNil(CircumferenceProgress.change(key: "biceps_l", readings: sparse,
                                                  from: "2026-08-16", to: "2026-09-06"))
        // Asking over the interval the data actually covers works.
        XCTAssertNotNil(CircumferenceProgress.change(key: "biceps_l", readings: sparse,
                                                     from: "2026-05-01", to: "2026-09-06"))
    }

    /// A reference that drifts a little — a missed measurement week — is still usable.
    func testASmallDriftIsStillUsable() throws {
        let change = try XCTUnwrap(CircumferenceProgress.change(
            key: "biceps_l", readings: growingSeries, from: "2026-08-18", to: "2026-09-06"))
        XCTAssertEqual(change.fromDay, "2026-08-16")
    }

    /// Both ends resolving to the SAME reading is not a change of zero — it is one measurement, and
    /// reporting "0.0 cm" would imply it was taken twice.
    func testOneReadingIsNotAChangeOfZero() {
        let single = [reading("2026-09-06", 37.1)]
        XCTAssertNil(CircumferenceProgress.change(key: "biceps_l", readings: single,
                                                  from: "2026-09-01", to: "2026-09-06"))
    }

    /// Nothing before the reference point means no comparison, rather than borrowing the first reading.
    func testNothingBeforeTheReferenceMeansNoComparison() {
        XCTAssertNil(CircumferenceProgress.change(key: "biceps_l", readings: growingSeries,
                                                  from: "2026-07-01", to: "2026-09-06"))
    }

    // MARK: - The wearer's own scatter

    /// The typical step is the median move between consecutive readings — measured from this person's
    /// own series, not asserted as a fixed figure.
    func testTheTypicalStepComesFromTheWearersOwnSeries() throws {
        // Steps: 0.2, 0.1, 0.3, 0.2, 0.3 → sorted 0.1 0.2 0.2 0.3 0.3 → median 0.2
        let step = try XCTUnwrap(CircumferenceProgress.typicalStep(growingSeries))
        XCTAssertEqual(step, 0.2, accuracy: 1e-9)
    }

    /// A change no bigger than that scatter is not called movement. It does not mean nothing happened —
    /// it means this series cannot separate what happened from how the tape was held.
    func testAChangeInsideTheScatterIsNotCalledMovement() throws {
        let change = try XCTUnwrap(CircumferenceProgress.change(
            key: "biceps_l", readings: growingSeries, from: "2026-08-30", to: "2026-09-06"))
        XCTAssertEqual(change.deltaCm, 0.3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(change.typicalStepCm), 0.2, accuracy: 1e-9)
        XCTAssertTrue(change.exceedsTypicalStep)

        // The same series, over a stretch where it barely moved.
        let flat = [("2026-08-02", 36.0), ("2026-08-09", 36.4), ("2026-08-16", 36.0),
                    ("2026-08-23", 36.4), ("2026-08-30", 36.1)].map { reading($0.0, $0.1) }
        let quiet = try XCTUnwrap(CircumferenceProgress.change(
            key: "biceps_l", readings: flat, from: "2026-08-02", to: "2026-08-30"))
        XCTAssertEqual(quiet.deltaCm, 0.1, accuracy: 1e-9)
        XCTAssertFalse(quiet.exceedsTypicalStep)
    }

    /// A single reading has no scatter to measure.
    func testASingleReadingHasNoScatter() {
        XCTAssertNil(CircumferenceProgress.typicalStep([reading("2026-09-06", 37.1)]))
        XCTAssertNil(CircumferenceProgress.typicalStep([]))
    }

    /// Input order does not change the answer.
    func testTheAnswerDoesNotDependOnInputOrder() throws {
        let shuffled = growingSeries.reversed().map { $0 }
        let a = try XCTUnwrap(CircumferenceProgress.change(key: "biceps_l", readings: growingSeries,
                                                           from: "2026-08-16", to: "2026-09-06"))
        let b = try XCTUnwrap(CircumferenceProgress.change(key: "biceps_l", readings: shuffled,
                                                           from: "2026-08-16", to: "2026-09-06"))
        XCTAssertEqual(a, b)
    }
}

/// Pins the tally that exists for the weeks the scale refuses to move.
final class CircumferenceTotalTests: XCTestCase {

    private func change(_ key: String, _ delta: Double, scatter: Double?) -> CircumferenceChange {
        CircumferenceChange(key: key, fromValue: 100, fromDay: "2026-08-01",
                            toValue: 100 + delta, toDay: "2026-09-06", typicalStepCm: scatter)
    }

    /// Loss and gain are reported apart, never netted. A centimetre off the waist and one onto the arm
    /// is the recomposition people are after; netting it to zero reports the best outcome as none.
    func testLossAndGainAreReportedSeparately() {
        let total = CircumferenceProgress.total([
            change("waist", -2.4, scatter: 0.3),
            change("abdomen", -1.7, scatter: 0.3),
            change("biceps_l", 0.9, scatter: 0.2),
        ])
        XCTAssertEqual(total.lostCm, 4.1, accuracy: 1e-9)
        XCTAssertEqual(total.gainedCm, 0.9, accuracy: 1e-9)
        XCTAssertEqual(total.shrinkingSites, 2)
        XCTAssertEqual(total.growingSites, 1)
        XCTAssertTrue(total.hasMovement)
    }

    /// THE rule that keeps this from being a motivational fiction: thirteen sites of pure scatter must
    /// not add up to a confident number.
    func testScatterDoesNotAddUpToProgress() {
        let noise = (1...13).map { change("site\($0)", $0.isMultiple(of: 2) ? 0.2 : -0.2,
                                          scatter: 0.3) }
        let total = CircumferenceProgress.total(noise)
        XCTAssertEqual(total.lostCm, 0)
        XCTAssertEqual(total.gainedCm, 0)
        XCTAssertFalse(total.hasMovement)
        // The sites were still compared — they simply did not move enough to count.
        XCTAssertEqual(total.comparedSites, 13)
    }

    /// A site whose scatter is unknown counts on any non-zero change — with one reading there is
    /// nothing to compare the movement against, so refusing it outright would hide real change.
    func testAnUnknownScatterCountsOnAnyMovement() {
        let total = CircumferenceProgress.total([change("waist", -1.2, scatter: nil)])
        XCTAssertEqual(total.lostCm, 1.2, accuracy: 1e-9)
        XCTAssertEqual(total.shrinkingSites, 1)
    }

    /// Nothing compared means nothing claimed.
    func testNothingComparedClaimsNothing() {
        let total = CircumferenceProgress.total([])
        XCTAssertFalse(total.hasMovement)
        XCTAssertEqual(total.comparedSites, 0)
    }
}
