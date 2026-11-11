import XCTest
@testable import NoopCore

/// What Today's measure tiles say beside the figure on both phones (`MeasureTileReading`): the change against the
/// usual, its colour, and what a tile over two columns adds.
final class MeasureTileReadingTests: XCTestCase {
    func testTheChangeAndTheSummaryReadTheSameUsual() {
        let rhr: [Double] = [52, 54, 53, 51, 55, 52, 53, 54, 58]
        XCTAssertEqual(MeasureTileReading.delta(key: "rhr", values: rhr), "↗ +5")
        XCTAssertEqual(MeasureTileReading.tone(key: "rhr", values: rhr), .large)
        let summary = MeasureTileReading.summary(key: "rhr", values: rhr)
        XCTAssertEqual(summary?.usual, "53")
        XCTAssertEqual(summary?.low, "51")
        XCTAssertEqual(summary?.high, "58")
    }

    func testSleepReadsAsHoursAndStressHasNoSummary() {
        let sleep: [Double] = [420, 450, 400, 480, 435, 410, 445, 470, 455]
        XCTAssertEqual(MeasureTileReading.summary(key: "sleep_total_min", values: sleep)?.low, "6:40")
        XCTAssertNil(MeasureTileReading.summary(key: "stress", values: sleep))
        XCTAssertNil(MeasureTileReading.summary(key: "hrv", values: [50, 52]))
    }
}
