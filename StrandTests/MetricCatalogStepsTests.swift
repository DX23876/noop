import XCTest
@testable import Strand

final class MetricCatalogStepsTests: XCTestCase {
    func testTodayStepsUsesMeasuredWhoopSeriesWhenAvailable() {
        let metric = MetricCatalog.todayStepsMetric(hasMeasuredSteps: true)

        XCTAssertEqual(metric?.key, "steps")
        XCTAssertEqual(metric?.source, "my-whoop")
        XCTAssertEqual(MetricCatalog.all.first(where: { $0.key == "steps" })?.source, "my-whoop")
    }

    func testTodayStepsUsesWhoopFourEstimateWhenMeasuredSeriesIsUnavailable() {
        let metric = MetricCatalog.todayStepsMetric(hasMeasuredSteps: false)

        XCTAssertEqual(metric?.key, "steps_est")
        XCTAssertEqual(metric?.source, "my-whoop")
    }

    func testAppleHealthStepsRemainsAnIndependentCatalogMetric() {
        let metric = MetricCatalog.metric(key: "steps", source: "apple-health")

        XCTAssertEqual(metric?.id, "apple-health:steps")
    }
}
