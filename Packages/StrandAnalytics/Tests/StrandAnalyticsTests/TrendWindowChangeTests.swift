import XCTest
@testable import StrandAnalytics

/// One answer to "did it move over this window".
///
/// The Trends tab had three, and the two on the same screen could contradict each other in front of
/// the wearer. These pin the resolver itself, not its call sites: counting the gated readers passes
/// while a fourth one works the question out on its own.
final class TrendWindowChangeTests: XCTestCase {

    private func series(_ pairs: [(String, Double)]) -> [(key: String, value: Double)] {
        pairs.map { (key: $0.0, value: $0.1) }
    }

    func testTheLaterHalfIsComparedWithTheEarlierOne() throws {
        let moved = try XCTUnwrap(TrendWindow.change(
            of: series([("2026-11-01", 50), ("2026-11-02", 50), ("2026-11-03", 50),
                        ("2026-11-09", 60), ("2026-11-10", 60), ("2026-11-11", 60)]),
            after: "2026-10-31", cut: "2026-11-05", minimumReadings: 2))

        XCTAssertEqual(moved.beforeMean, 50)
        XCTAssertEqual(moved.nowMean, 60)
        XCTAssertEqual(moved.beforeCount, 3)
        XCTAssertEqual(moved.nowCount, 3)
        XCTAssertEqual(moved.absolute, 10)
        XCTAssertEqual(try XCTUnwrap(moved.relative), 0.2, accuracy: 0.000_001)
    }

    /// The reason for splitting by key rather than by how many readings there are: with the window's
    /// earlier half empty, a count-split would put both halves inside the last few days and report a
    /// move that covers neither half. By key there is nothing to compare, and nothing is claimed.
    func testAWindowWhoseEarlierHalfIsEmptyHasNoAnswer() {
        XCTAssertNil(TrendWindow.change(
            of: series([("2026-11-09", 60), ("2026-11-10", 61), ("2026-11-11", 62), ("2026-11-12", 63)]),
            after: "2026-10-14", cut: "2026-11-05", minimumReadings: 2))
    }

    func testAHalfWithTooFewReadingsHasNoAnswer() {
        let one = series([("2026-11-04", 50), ("2026-11-09", 60), ("2026-11-10", 60)])
        XCTAssertNil(TrendWindow.change(of: one, after: nil, cut: "2026-11-05", minimumReadings: 2),
                     "the mean of one reading is that reading, not a mean")
        XCTAssertNotNil(TrendWindow.change(of: one, after: nil, cut: "2026-11-05", minimumReadings: 1))
    }

    /// A third of the span, never fewer than two, whatever the span.
    func testTheCoverageRuleIsAThirdOfTheSpanAndAtLeastTwo() {
        XCTAssertEqual(TrendWindow.minimumReadings(forSpan: 7), 2)
        XCTAssertEqual(TrendWindow.minimumReadings(forSpan: 30), 10)
        XCTAssertEqual(TrendWindow.minimumReadings(forSpan: 90), 30)
        XCTAssertEqual(TrendWindow.minimumReadings(forSpan: 1), 2)
        XCTAssertEqual(TrendWindow.minimumReadings(forSpan: 0), 2)
    }

    /// Nil `after` means the earlier half simply starts at the first reading, which is what a chart
    /// card needs: its window is whatever it is showing.
    func testWithNoLowerBoundTheEarlierHalfStartsAtTheFirstReading() throws {
        let moved = try XCTUnwrap(TrendWindow.change(
            of: series([("2026-01-01", 10), ("2026-01-02", 10), ("2026-11-09", 20), ("2026-11-10", 20)]),
            after: nil, cut: "2026-06-01", minimumReadings: 2))
        XCTAssertEqual(moved.beforeMean, 10)
        XCTAssertEqual(moved.nowMean, 20)
    }

    /// Starting at zero has no share to report. A relative change would be a division by nothing
    /// dressed up as an enormous move, so only the absolute one is offered.
    func testAStartOfZeroHasAnAbsoluteMoveAndNoShare() throws {
        let moved = try XCTUnwrap(TrendWindow.change(
            of: series([("2026-11-01", 0), ("2026-11-02", 0), ("2026-11-09", 4), ("2026-11-10", 6)]),
            after: nil, cut: "2026-11-05", minimumReadings: 2))
        XCTAssertEqual(moved.absolute, 5)
        XCTAssertNil(moved.relative)
    }

    /// A fall is a negative move, and the share is negative with it: the readers colour by direction,
    /// so a sign flip here would turn a worse week into a better one on the screen.
    func testAFallIsSignedBothWays() throws {
        let moved = try XCTUnwrap(TrendWindow.change(
            of: series([("2026-11-01", 100), ("2026-11-02", 100), ("2026-11-09", 75), ("2026-11-10", 75)]),
            after: nil, cut: "2026-11-05", minimumReadings: 2))
        XCTAssertEqual(moved.absolute, -25)
        XCTAssertEqual(try XCTUnwrap(moved.relative), -0.25, accuracy: 0.000_001)
    }

    /// Dates work as the key too, which is how the chart card reads it without turning its UTC-parsed
    /// dates back into local day strings, a round trip that shifts every point west of UTC.
    func testDatesWorkAsTheKeyAsWellAsDayStrings() throws {
        let day = 86_400.0
        let base = Date(timeIntervalSince1970: 1_767_225_600)
        let points: [(key: Date, value: Double)] = [
            (base, 10), (base.addingTimeInterval(day), 10),
            (base.addingTimeInterval(6 * day), 14), (base.addingTimeInterval(7 * day), 14)
        ]
        let moved = try XCTUnwrap(TrendWindow.change(of: points, after: nil,
                                                     cut: base.addingTimeInterval(3 * day),
                                                     minimumReadings: 2))
        XCTAssertEqual(moved.beforeMean, 10)
        XCTAssertEqual(moved.nowMean, 14)
    }
}
