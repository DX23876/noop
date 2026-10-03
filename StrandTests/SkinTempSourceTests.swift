import XCTest
import WhoopStore
@testable import Strand

final class SkinTempSourceTests: XCTestCase {
    private func row(_ day: String, source: DailyMetricSource,
                     absolute: Double? = nil, deviation: Double? = nil) -> SourcedDailyMetric {
        let metric = DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil,
                                 remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                                 avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil,
                                 skinTempDevC: deviation, skinTempC: absolute)
        return SourcedDailyMetric(metric: metric, source: source)
    }

    func testAbsoluteSourceFollowsTheColumnUsedForEachDay() {
        let rows = [
            row("2026-09-27", source: .whoopImport, deviation: 34.37),
            row("2026-09-27", source: .noopComputed, absolute: 35.65),
            row("2026-09-28", source: .noopComputed, absolute: 35.69),
            row("2026-09-29", source: .whoopImport, deviation: 34.12),
        ]
        let sources = skinTempSourceByDay(rows, leadsAbsolute: true)

        // A computed measured absolute wins over an imported absolute in the deviation column.
        XCTAssertEqual(sources["2026-09-27"], "my-whoop-noop")
        XCTAssertEqual(sources["2026-09-28"], "my-whoop-noop")
        XCTAssertEqual(sources["2026-09-29"], "my-whoop")
    }

    func testDeviationSourceDoesNotInheritAnAbsoluteOrAppleRow() {
        let rows = [
            row("2026-09-27", source: .whoopImport, deviation: 34.37),
            row("2026-09-27", source: .noopComputed, deviation: 0.32),
            row("2026-09-28", source: .appleHealth, deviation: 0.14),
            row("2026-09-29", source: .localCache, deviation: -0.21),
        ]
        let sources = skinTempSourceByDay(rows, leadsAbsolute: false)

        XCTAssertEqual(sources["2026-09-27"], "my-whoop-noop")
        XCTAssertNil(sources["2026-09-28"])
        XCTAssertEqual(sources["2026-09-29"], "local-cache")
    }
}
