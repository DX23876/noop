#if !os(watchOS)
import XCTest
@testable import StrandDesign

final class StepsBarAxisTests: XCTestCase {
    func testStepAxisIncludesOccupiedBlockAndKeepsZero() {
        for (maximum, upper) in [(0.0, 5000.0), (4999, 5000), (5000, 5000),
                                 (5001, 10000), (19000, 20000), (20001, 25000)] {
            let chart = TrendChart(points: [.init(date: Date(), value: maximum)],
                                   showsBars: true, yAxisStep: 5000)
            XCTAssertEqual(chart.plotYDomain, 0...upper)
        }
    }

    /// Bar values get their room as data-space headroom above the top step; the grid steps themselves
    /// stay where they were, and charts without bar values keep the exact step domain.
    func testBarValuesAddHeadroomAboveTheTopStep() {
        for (maximum, top) in [(4999.0, 5000.0), (12_901, 15_000), (15_000, 15_000)] {
            let chart = TrendChart(points: [.init(date: Date(), value: maximum)],
                                   showsBars: true, yAxisStep: 5000, showsBarValues: true)
            XCTAssertEqual(chart.plotYDomain.lowerBound, 0)
            XCTAssertEqual(chart.plotYDomain.upperBound, top * TrendChart.barValueHeadroom, accuracy: 0.001)
            XCTAssertGreaterThan(chart.plotYDomain.upperBound, maximum)
        }
    }

    func testExistingChartDomainUnchangedWithoutStepConfiguration() {
        let chart = TrendChart(points: [], valueRange: 40...80, showsBars: true)
        XCTAssertEqual(chart.plotYDomain, 0...80)
        XCTAssertEqual(TrendChart(points: [], valueRange: 40...80).plotYDomain, 40...80)
    }
}
#endif
