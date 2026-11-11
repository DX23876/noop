import XCTest
@testable import NoopCore

/// A usual day's burn on both phones (`EnergyUsualDay`): the median of the finished days, from five on.
final class EnergyUsualDayTests: XCTestCase {
    func testTheMedianOfFinishedDaysLeavesTodayOut() {
        let days: [(day: String, total: Double?)] = [("2026-11-01", 2000), ("2026-11-02", 2200), ("2026-11-03", nil),
                                                     ("2026-11-04", 2100), ("2026-11-05", 1900), ("2026-11-06", 2400),
                                                     ("2026-11-07", 500)]
        XCTAssertEqual(EnergyUsualDay.total(days, today: "2026-11-07"), 2100)
        XCTAssertNil(EnergyUsualDay.total(Array(days.prefix(4)), today: "2026-11-07"))
    }
}
