import XCTest
@testable import StrandAnalytics

/// Pins the resolver that ends the duplicate storage of body data.
///
/// The defining property is the one the energy path already warned about: a measurement taken after a
/// day must never be what that day is priced with.
final class BodyMetricsTests: XCTestCase {

    private func reading(_ day: String, _ value: Double, at takenAt: Int = 0,
                         source: String = "manual") -> BodyReading {
        BodyReading(day: day, takenAt: takenAt, value: value, source: source)
    }

    private lazy var metrics = BodyMetrics(readings: [
        "weight": [reading("2026-01-10", 82), reading("2026-03-01", 80), reading("2026-03-20", 79.4)],
        "waist": [reading("2026-01-10", 88), reading("2026-03-01", 85)],
        "biceps_l": [reading("2026-03-01", 36.5)],
        "biceps_r": [reading("2026-03-01", 37.2)],
    ])

    /// `latest` answers what is true now.
    func testLatestAnswersTheNewestReading() {
        XCTAssertEqual(metrics.latest("weight")?.value, 79.4)
        XCTAssertEqual(metrics.latest("weight")?.day, "2026-03-20")
        XCTAssertNil(metrics.latest("chest"))
    }

    /// `asOf` answers what was true then.
    func testAsOfAnswersTheReadingInForceThen() {
        XCTAssertEqual(metrics.value("weight", on: "2026-02-15"), 82)
        XCTAssertEqual(metrics.value("weight", on: "2026-03-01"), 80)
        XCTAssertEqual(metrics.value("weight", on: "2026-03-19"), 80)
        XCTAssertEqual(metrics.value("weight", on: "2026-03-20"), 79.4)
    }

    /// THE guarantee: nothing measured later reaches a day before it. A day preceding every reading
    /// has no answer rather than borrowing the first one.
    func testNoReadingEverReachesBackwards() {
        XCTAssertNil(metrics.asOf("weight", day: "2026-01-09"))
        XCTAssertNil(metrics.value("weight", on: "2025-12-31"))
    }

    /// Input order does not change any answer.
    func testTheAnswerDoesNotDependOnInputOrder() {
        let shuffled = BodyMetrics(readings: [
            "weight": [reading("2026-03-20", 79.4), reading("2026-01-10", 82), reading("2026-03-01", 80)],
        ])
        XCTAssertEqual(shuffled.value("weight", on: "2026-02-15"), 82)
        XCTAssertEqual(shuffled.latest("weight")?.value, 79.4)
    }

    /// Two readings on one day resolve by instant, so a correction entered later that day wins.
    func testTwoReadingsOnOneDayResolveByInstant() {
        let sameDay = BodyMetrics(readings: [
            "weight": [reading("2026-03-01", 80, at: 100), reading("2026-03-01", 79, at: 900)],
        ])
        XCTAssertEqual(sameDay.value("weight", on: "2026-03-01"), 79)
        XCTAssertEqual(sameDay.latest("weight")?.value, 79)
    }

    /// A caller that cares about staleness names its own window, and gets nothing when the reading is
    /// older than that.
    func testAStalenessWindowIsTheCallersToApply() {
        XCTAssertEqual(metrics.asOf("weight", day: "2026-03-25", maximumAgeDays: 30)?.value, 79.4)
        XCTAssertNil(metrics.asOf("weight", day: "2026-06-01", maximumAgeDays: 30))
        // Without a window the same question still answers — staleness is a policy, not a fact.
        XCTAssertEqual(metrics.value("weight", on: "2026-06-01"), 79.4)
    }

    /// A reading's age is measured against the day being asked about.
    func testAReadingKnowsHowOldItIs() {
        let reading = try? XCTUnwrap(metrics.asOf("weight", day: "2026-03-30"))
        XCTAssertEqual(reading?.ageDays(on: "2026-03-30"), 10)
    }

    /// The source rides along, so a DEXA result and a tape estimate never end up on one line.
    func testTheSourceRidesAlong() {
        let mixed = BodyMetrics(readings: [
            "body_fat": [reading("2026-01-01", 18, source: "dexa"),
                         reading("2026-02-01", 20, source: "navy")],
        ])
        XCTAssertEqual(mixed.asOf("body_fat", day: "2026-01-15")?.source, "dexa")
        XCTAssertEqual(mixed.latest("body_fat")?.source, "navy")
    }

    /// Non-finite readings never enter the resolver.
    func testNonFiniteReadingsAreDropped() {
        let dirty = BodyMetrics(readings: ["weight": [reading("2026-01-01", .nan),
                                                      reading("2026-01-02", 80)]])
        XCTAssertEqual(dirty.series("weight").count, 1)
        XCTAssertEqual(dirty.latest("weight")?.value, 80)
    }

    /// An empty resolver answers nothing rather than a default, so a fresh install cannot be handed
    /// an invented body.
    func testAnEmptyResolverAnswersNothing() {
        XCTAssertNil(BodyMetrics.empty.latest("weight"))
        XCTAssertNil(BodyMetrics.empty.value("weight", on: "2026-03-01"))
        XCTAssertTrue(BodyMetrics.empty.measuredKeys.isEmpty)
    }

    /// Only keys that actually hold readings are reported as measured.
    func testOnlyKeysWithReadingsCountAsMeasured() {
        XCTAssertEqual(metrics.measuredKeys, ["biceps_l", "biceps_r", "waist", "weight"])
    }
}
