import XCTest
@testable import Strand

/// The energy refresh cost line in the log header: silent until a refresh ran, then totals and the longest.
@MainActor
final class EnergyRefreshStatsTests: XCTestCase {

    override func setUp() async throws { EnergyRefreshStats.reset() }
    override func tearDown() async throws { EnergyRefreshStats.reset() }

    func testItSaysNothingBeforeARefresh() {
        XCTAssertTrue(EnergyRefreshStats.summaryLines().isEmpty)
    }

    func testTheLineCarriesTotalsAndTheLongest() {
        EnergyRefreshStats.record(days: 1, millis: 40)
        EnergyRefreshStats.record(days: 120, millis: 9_000)
        EnergyRefreshStats.record(days: 2, millis: 60)
        XCTAssertEqual(EnergyRefreshStats.summaryLines(),
                       ["Energy refreshes: count=3 days=123 totalMs=9100 avgMs=3033 longestMs=9000"])
    }
}
