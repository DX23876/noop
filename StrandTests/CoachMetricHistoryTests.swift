import XCTest
@testable import Strand

final class CoachMetricHistoryTests: XCTestCase {
    func testLongHistoryIsAggregatedInsteadOfReturningRawReadings() {
        var points: [CoachMetricHistory.Point] = []
        for month in 1...36 {
            let year = 2023 + ((month - 1) / 12)
            let monthOfYear = ((month - 1) % 12) + 1
            let day = String(format: "%d-%02d-01", year, monthOfYear)
            points.append(.init(day: day, value: 80 - Double(month) * 0.1))
        }
        let report = CoachMetricHistory.report(metric: "Weight", source: "Apple Health", unit: "kg", points: points)
        XCTAssertTrue(report.contains("LOCAL METRIC HISTORY — Weight (Apple Health)"))
        XCTAssertTrue(report.contains("Aggregated timeline (not raw readings):"))
        XCTAssertFalse(report.contains("2023-01-01: 79.9"), "individual rows must not be exported")
    }

    func testSparseHistoryReportsChangeAndHonestTrend() {
        let report = CoachMetricHistory.report(metric: "Weight", source: "Apple Health", unit: "kg", points: [
            .init(day: "2024-01-01", value: 90), .init(day: "2024-06-01", value: 87),
            .init(day: "2025-01-01", value: 84), .init(day: "2025-06-01", value: 82)
        ])
        XCTAssertTrue(report.contains("Summary: mean"), report)
        XCTAssertTrue(report.contains("falling"))
        XCTAssertFalse(report.contains("earliest 90"), report)
        XCTAssertFalse(report.contains("latest 82"), report)
        XCTAssertFalse(report.contains("range"), report)
    }

    func testOnePointDoesNotInventATrend() {
        let report = CoachMetricHistory.report(metric: "Weight", source: "Apple Health", unit: "kg", points: [
            .init(day: "2026-01-01", value: 80)
        ])
        XCTAssertEqual(report, "Not enough local Weight history to analyse a privacy-preserving trend yet.")
    }

    func testAutomaticSelectionPrefersWiderCoverageWithoutCombiningSources() {
        let selected = CoachMetricHistory.bestAvailableSeries(from: [
            .init(source: "apple-health", points: [
                .init(day: "2026-06-01", value: 80), .init(day: "2026-06-08", value: 79.5)
            ]),
            .init(source: "garmin-import", points: [
                .init(day: "2023-06-01", value: 84), .init(day: "2026-06-01", value: 80)
            ])
        ])

        XCTAssertEqual(selected?.source, "garmin-import")
        XCTAssertEqual(selected?.points.count, 2, "sources must not be blended into one trend")
    }

    func testSourceSummaryKeepsTimelineProvenanceWithoutReadings() {
        let summary = CoachMetricHistory.sourceSummary(from: [
            .init(day: "2024-01-03", value: 81, source: "apple-health", sourceKey: "weight"),
            .init(day: "2024-12-30", value: 79, source: "apple-health", sourceKey: "weight"),
            .init(day: "2025-01-01", value: 79, source: "my-whoop", sourceKey: "weight")
        ]) { source in
            source == "apple-health" ? "Apple Health" : "WHOOP / NOOP"
        }

        XCTAssertEqual(summary, "Apple Health (2024-01-03 → 2024-12-30; 2 days); WHOOP / NOOP (2025-01-01; 1 days)")
        XCTAssertFalse(summary.contains("81"), "provenance must not leak individual readings")
    }

    func testSparseTimelineIsWithheldInsteadOfRelabellingSingleReadings() {
        let report = CoachMetricHistory.report(metric: "Weight", source: "Apple Health", unit: "kg", points: [
            .init(day: "2024-01-01", value: 90), .init(day: "2025-01-01", value: 85)
        ])

        XCTAssertEqual(report, "Not enough local Weight history to analyse a privacy-preserving trend yet.")
    }
}
