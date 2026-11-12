import XCTest
@testable import NoopCore

final class MetricDetailInsightsTests: XCTestCase {
    private func days(_ values: [Double], from start: Int = 1) -> [(day: String, value: Double)] {
        values.enumerated().map { i, v in (String(format: "2026-10-%02d", start + i), v) }
    }

    func testPreviousWindowIsAsLongAsTheVisibleOne() {
        let series = days([1, 2, 3, 4, 5, 6, 7])
        let windowed = Array(series.suffix(3))
        XCTAssertEqual(MetricDetailInsights.previousWindow(series: series, windowed: windowed, isAll: false).map(\.value),
                       [2, 3, 4])
        XCTAssertTrue(MetricDetailInsights.previousWindow(series: series, windowed: windowed, isAll: true).isEmpty)
        XCTAssertTrue(MetricDetailInsights.previousWindow(series: series, windowed: series, isAll: false).isEmpty)
    }

    func testCorrelationsKeepStrongPairsAndDropAScoreBesideItsInput() {
        let base = (0..<14).map { Double($0) }
        let windowed = days(base)
        let rising = MetricDescriptor(key: "steps", title: "Steps", category: "Effort", unit: "", source: "my-whoop",
                                      icon: "", decimals: 0, higherIsBetter: true)
        let charge = MetricDescriptor(key: "recovery", title: "Charge", category: "Charge", unit: "%", source: "my-whoop",
                                      icon: "", decimals: 0, higherIsBetter: true)
        let noise = MetricDescriptor(key: "avg_hr", title: "Average Heart Rate", category: "Heart", unit: "bpm",
                                     source: "my-whoop", icon: "", decimals: 0, higherIsBetter: nil)
        let rows = MetricDetailInsights.correlations(metricKey: "hrv", windowed: windowed, others: [
            (rising, days(base.map { $0 * 2 + 1 })),
            (charge, days(base.map { 100 - $0 })),
            (noise, days([5, 1, 5, 1, 5, 1, 5, 1, 5, 1, 5, 1, 5, 1])),
        ])
        XCTAssertEqual(rows.map(\.key), ["steps"])
        XCTAssertEqual(rows.first?.n, 14)
        XCTAssertEqual(rows.first?.r ?? 0, 1, accuracy: 1e-9)
    }

    func testTooFewSharedDaysGiveNoCorrelation() {
        let other = MetricDescriptor(key: "steps", title: "Steps", category: "Effort", unit: "", source: "my-whoop",
                                     icon: "", decimals: 0, higherIsBetter: true)
        let rows = MetricDetailInsights.correlations(metricKey: "hrv", windowed: days([1, 2, 3, 4, 5]),
                                                     others: [(other, days([2, 4, 6, 8, 10]))])
        XCTAssertTrue(rows.isEmpty)
    }
}
