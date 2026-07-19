import XCTest
@testable import Strand

final class MetricCatalogStepsTests: XCTestCase {
    func testTodayStepsUsesMeasuredWhoopSeriesWhenAvailable() {
        let metric = MetricCatalog.todayStepsMetric(hasMeasuredSteps: true)

        XCTAssertEqual(metric?.key, "steps")
        XCTAssertEqual(metric?.source, "my-whoop")
    }

    func testTodayStepsUsesWhoopFourEstimateWhenMeasuredSeriesIsUnavailable() {
        let metric = MetricCatalog.todayStepsMetric(hasMeasuredSteps: false)

        XCTAssertEqual(metric?.key, "steps_est")
        XCTAssertEqual(metric?.source, "my-whoop")
    }

    /// #377 parity: with no measured strap count but an imported Apple Health count for the day, Today
    /// shows and taps through to the imported value — NOT the motion estimate.
    func testTodayStepsPrefersImportedAppleHealthOverEstimate() {
        let metric = MetricCatalog.todayStepsMetric(hasMeasuredSteps: false, hasImportedSteps: true)

        XCTAssertEqual(metric?.key, "steps")
        XCTAssertEqual(metric?.source, "apple-health")
    }

    /// A measured strap count always wins, even when an import also exists (real ?: imported ?: estimate).
    func testMeasuredStepsWinOverImported() {
        let metric = MetricCatalog.todayStepsMetric(hasMeasuredSteps: true, hasImportedSteps: true)

        XCTAssertEqual(metric?.key, "steps")
        XCTAssertEqual(metric?.source, "my-whoop")
    }

    func testAppleHealthStepsRemainsAnIndependentCatalogMetric() {
        let metric = MetricCatalog.metric(key: "steps", source: "apple-health")

        XCTAssertEqual(metric?.id, "apple-health:steps")
    }

    /// Both measured WHOOP steps and the WHOOP 4.0 estimate must be resolvable by EXACT source, so the
    /// Today card/tile can route to them (via `.metricSourced` / `todayStepsMetric`) without depending on
    /// catalog declaration order.
    func testWhoopStepsAreResolvableBySource() {
        XCTAssertEqual(MetricCatalog.metric(key: "steps", source: "my-whoop")?.id, "my-whoop:steps")
        XCTAssertEqual(MetricCatalog.metric(key: "steps_est", source: "my-whoop")?.id, "my-whoop:steps_est")
    }

    /// Regression guard: the bare-key `first { $0.key == "steps" }` resolvers that are NOT source-aware
    /// (LabBookView's correlation descriptors, CompareView's default/legacy picks, the TabRoute `.metric`
    /// fallback) must keep resolving Apple Health, exactly as before the measured-WHOOP entry was added.
    /// The measured entry is declared AFTER apple-health precisely so it never captures these lookups —
    /// the Today surface reaches it explicitly instead. If a future edit reorders the catalog, this fails
    /// loudly rather than silently emptying those screens for an Apple-Health-steps user.
    func testBareKeyStepsResolutionStaysAppleHealth() {
        XCTAssertEqual(MetricCatalog.all.first(where: { $0.key == "steps" })?.source, "apple-health")
    }
}
