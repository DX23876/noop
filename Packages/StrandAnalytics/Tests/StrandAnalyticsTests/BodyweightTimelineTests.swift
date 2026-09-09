import XCTest
@testable import StrandAnalytics

/// Pins the weigh-in lookup that prices bodyweight training volume.
///
/// Every test here is about the boundary between "close enough to use" and "say nothing" — the whole
/// value of this type is that it refuses to answer rather than carrying a year-old weight forward.
final class BodyweightTimelineTests: XCTestCase {

    private let timeline = BodyweightTimeline(points: [
        ("2026-01-10", 82), ("2026-03-01", 80), ("2026-03-20", 79.4),
    ])

    /// An exact day returns exactly that measurement.
    func testAnExactDayReturnsItsOwnMeasurement() {
        XCTAssertEqual(timeline.kg(onDay: "2026-03-01"), 80)
    }

    /// A day between two weigh-ins takes the NEARER one — never an interpolation between them, which
    /// would invent a daily series out of two points.
    func testADayBetweenWeighInsTakesTheNearerOne() {
        XCTAssertEqual(timeline.kg(onDay: "2026-03-05"), 80)
        XCTAssertEqual(timeline.kg(onDay: "2026-03-16"), 79.4)
    }

    /// Beyond the window there is no answer. A session from long before anyone owned a scale must not
    /// be priced at a weight recorded years later.
    func testBeyondTheWindowThereIsNoAnswer() {
        XCTAssertNil(timeline.kg(onDay: "2025-06-01"))
        XCTAssertNil(timeline.kg(onDay: "2026-07-01"))
        XCTAssertEqual(timeline.kg(onDay: "2026-05-18"), 79.4, "59 days after the last weigh-in")
        XCTAssertNil(timeline.kg(onDay: "2026-05-20"), "61 days after it")
    }

    /// An equidistant day keeps the EARLIER measurement, so the answer never depends on ordering.
    func testATieKeepsTheEarlierMeasurement() {
        let even = BodyweightTimeline(points: [("2026-03-01", 80), ("2026-03-11", 78)])
        XCTAssertEqual(even.kg(onDay: "2026-03-06"), 80)
    }

    /// An empty timeline answers nothing, which is what makes the bodyweight figures simply not appear.
    func testAnEmptyTimelineAnswersNothing() {
        XCTAssertNil(BodyweightTimeline(points: []).kg(onDay: "2026-03-01"))
        XCTAssertTrue(BodyweightTimeline(points: [("2026-03-01", 0)]).isEmpty, "a zero is not a weigh-in")
    }
}
