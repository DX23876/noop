import XCTest
@testable import CoachAnalysis

final class AnalysisStatisticsTests: XCTestCase {

    func testDayKeyRoundTripsAndRejectsImpossibleDates() {
        XCTAssertEqual(DayKey.ordinal("1970-01-01"), 0)
        XCTAssertEqual(DayKey.string(DayKey.ordinal("2024-02-29")!), "2024-02-29")
        XCTAssertNil(DayKey.ordinal("2026-02-29"), "2026 is not a leap year")
        XCTAssertNil(DayKey.ordinal("2026-9-3"))
        XCTAssertEqual(DayKey.adding(1, to: "2025-12-31"), "2026-01-01")
        XCTAssertEqual(DayKey.adding(-1, to: "2024-03-01"), "2024-02-29")
        XCTAssertEqual(DayKey.isoWeekday(DayKey.ordinal("2026-09-23")!), 3, "a Wednesday")
        XCTAssertEqual(DayKey.isoWeekday(DayKey.ordinal("2026-09-27")!), 7, "a Sunday")
    }

    func testDescriptiveStatistics() {
        let xs = [2.0, 4, 4, 4, 5, 5, 7, 9]
        XCTAssertEqual(AnalysisStatistics.mean(xs), 5)
        XCTAssertEqual(AnalysisStatistics.median(xs), 4.5)
        XCTAssertEqual(AnalysisStatistics.standardDeviation(xs)!, 2.138, accuracy: 0.001)
        XCTAssertEqual(AnalysisStatistics.quantile([1, 2, 3, 4], 0.25)!, 1.75, accuracy: 1e-12)
        XCTAssertNil(AnalysisStatistics.mean([]))
    }

    func testCorrelationAndSlope() {
        let x = [1.0, 2, 3, 4, 5]
        XCTAssertEqual(AnalysisStatistics.olsSlope(x, x.map { 3 * $0 + 1 })!, 3, accuracy: 1e-12)
        XCTAssertEqual(AnalysisStatistics.pearson(x, x.map { -2 * $0 })!, -1, accuracy: 1e-12)
        // Monotone but not linear: Spearman sees a perfect ranking, Pearson does not.
        let y = x.map { $0 * $0 * $0 }
        XCTAssertEqual(AnalysisStatistics.spearman(x, y)!, 1, accuracy: 1e-12)
        XCTAssertLessThan(AnalysisStatistics.pearson(x, y)!, 1)
        XCTAssertEqual(AnalysisStatistics.ranks([10, 20, 20, 30]), [1, 2.5, 2.5, 4], "ties share the average rank")
    }

    func testBenjaminiHochbergMatchesTheReferenceProcedure() {
        // By hand: sorted 0.005, 0.01, 0.03, 0.04 → ×4/rank = 0.02, 0.02, 0.04, 0.04, then the running
        // minimum from the top. Same as R's p.adjust(method = "BH").
        let q = AnalysisStatistics.benjaminiHochberg([0.01, 0.04, 0.03, 0.005])
        XCTAssertEqual(q[0], 0.02, accuracy: 1e-12)
        XCTAssertEqual(q[1], 0.04, accuracy: 1e-12)
        XCTAssertEqual(q[2], 0.04, accuracy: 1e-12)
        XCTAssertEqual(q[3], 0.02, accuracy: 1e-12)
        XCTAssertEqual(AnalysisStatistics.benjaminiHochberg([0.5]), [0.5])
    }

    func testBootstrapIsDeterministicForASeed() {
        let values = (0..<60).map { Double($0 % 7) + 0.1 * Double($0) }
        let run = { (seed: UInt64) in
            AnalysisStatistics.blockBootstrap(count: values.count, seed: seed, estimate: AnalysisStatistics.mean(values)!) { idx in
                AnalysisStatistics.mean(idx.map { values[$0] })
            }
        }
        XCTAssertEqual(run(42), run(42))
        let boot = run(42)!
        XCTAssertLessThan(boot.lower, boot.estimate)
        XCTAssertGreaterThan(boot.upper, boot.estimate)
        XCTAssertLessThan(boot.p, 0.001, "a mean far from zero")
    }

    func testFnv1aIsTheStandard64BitHash() {
        // Reference values of 64-bit FNV-1a.
        XCTAssertEqual(AnalysisStatistics.fnv1a(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(AnalysisStatistics.fnv1a("a"), 0xaf63_dc4c_8601_ec8c)
    }
}
