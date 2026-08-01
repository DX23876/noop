import XCTest
@testable import Strand

/// Pins the window rule behind Liquid Today's detailed-tile sparklines.
///
/// The Weight tile showed a correct number and no graph. `windowedSpark` filtered the banked series by
/// DATE only (2 / 7 / 14 days), so a series that is sparse by nature — someone weighs themselves every
/// few weeks — had fewer than two points inside the window and the tile fell through to its
/// `Color.clear` placeholder. The number survived because `Repository.resolveWeightKg` takes the latest
/// series point regardless of date, which is exactly the "value right, graph gone" report.
///
/// `docs/FEATURES.md` promises the opposite ("Sparse series (e.g. weight) fall back to all history so a
/// tile never shows empty when data exists"), and classic Today keeps that promise for free: its
/// `windowedSpark` is count-based (`suffix(keyMetricsWindowDays)`). Liquid's date filter is not
/// pointless though — it stops a stale import from being read as a current trend (#23) — so it stays as
/// the normal path and the fallback only catches the case where it cannot draw a line at all.
///
/// Pure, so these run with no strap, no clock and no view.
final class LiquidSparkWindowTests: XCTestCase {

    private typealias Window = LiquidTodayView

    /// Seven consecutive days ending 2026-08-01, value == day of month.
    private var denseWeek: [(String, Double)] {
        (26...31).map { ("2026-07-\($0)", Double($0)) } + [("2026-08-01", 1)]
    }

    // MARK: - Dense series: the window is the whole story

    func testDenseSeriesReturnsExactlyTheWindowAndNeverFallsBack() {
        let spark = Window.windowedSpark(points: denseWeek, cutoffKey: "2026-07-29", maxPoints: 7)
        XCTAssertEqual(spark, [29, 30, 31, 1])
    }

    func testDenseSeriesKeepsOlderPointsOutOfTheWindow() {
        // The #23 guard: a two-day window must not show last week's numbers.
        let spark = Window.windowedSpark(points: denseWeek, cutoffKey: "2026-07-31", maxPoints: 2)
        XCTAssertEqual(spark, [31, 1])
    }

    // MARK: - Sparse series: the fallback that FEATURES.md promises

    func testSparseSeriesOutsideTheWindowFallsBackToRecentMeasurements() {
        // Weight, measured every few weeks — nothing inside a 7-day window ending 2026-08-01.
        let weight: [(String, Double)] = [("2026-06-14", 82.4), ("2026-06-30", 81.7), ("2026-07-11", 81.1)]
        let spark = Window.windowedSpark(points: weight, cutoffKey: "2026-07-26", maxPoints: 7)
        XCTAssertEqual(spark, [82.4, 81.7, 81.1], "a sparse tile must still draw its trend")
    }

    func testOneLonelyPointInTheWindowStillFallsBack() {
        // A single in-window point cannot draw a line, so the fallback has to widen it — this is the
        // boundary the date-only filter got wrong.
        let weight: [(String, Double)] = [("2026-06-30", 81.7), ("2026-07-11", 81.1), ("2026-07-28", 80.6)]
        let spark = Window.windowedSpark(points: weight, cutoffKey: "2026-07-26", maxPoints: 7)
        XCTAssertEqual(spark, [81.7, 81.1, 80.6])
    }

    func testFallbackIsBoundedByMaxPointsAndStaysChronological() {
        let monthly: [(String, Double)] = (1...20).map { ("2026-01-\(String(format: "%02d", $0))", Double($0)) }
        let spark = Window.windowedSpark(points: monthly, cutoffKey: "2026-07-26", maxPoints: 7)
        XCTAssertEqual(spark, [14, 15, 16, 17, 18, 19, 20], "newest maxPoints, oldest → newest")
    }

    // MARK: - Honest emptiness stays empty

    func testSinglePointSeriesStaysBelowTheDrawThreshold() {
        // One measurement in all of history is not a trend: the tile must keep showing no graph.
        let spark = Window.windowedSpark(points: [("2026-07-11", 81.1)], cutoffKey: "2026-07-26", maxPoints: 7)
        XCTAssertLessThan(spark.count, 2)
    }

    func testEmptySeriesReturnsNothing() {
        XCTAssertTrue(Window.windowedSpark(points: [], cutoffKey: "2026-07-26", maxPoints: 7).isEmpty)
    }
}
