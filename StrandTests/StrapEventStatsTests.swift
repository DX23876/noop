import XCTest
@testable import Strand

/// The strap-event counts in the log header: named without their raw number, most frequent first, silent
/// when nothing arrived.
@MainActor
final class StrapEventStatsTests: XCTestCase {

    override func setUp() async throws { StrapEventStats.reset() }
    override func tearDown() async throws { StrapEventStats.reset() }

    func testItSaysNothingWhenNoEventArrived() {
        XCTAssertTrue(StrapEventStats.summaryLines().isEmpty)
    }

    func testTheRawNumberIsStripped() {
        XCTAssertEqual(StrapEventStats.name(of: "BATTERY_LEVEL(3)"), "BATTERY_LEVEL")
        XCTAssertEqual(StrapEventStats.name(of: "WRIST_ON"), "WRIST_ON")
    }

    func testTheLineIsMostFrequentFirstWithStableTies() {
        for _ in 0..<3 { StrapEventStats.record("BATTERY_LEVEL(3)") }
        StrapEventStats.record("WRIST_ON(9)")
        StrapEventStats.record("DOUBLE_TAP(14)")
        XCTAssertEqual(StrapEventStats.summaryLines(),
                       ["Strap events: BATTERY_LEVEL=3 DOUBLE_TAP=1 WRIST_ON=1"])
    }
}
