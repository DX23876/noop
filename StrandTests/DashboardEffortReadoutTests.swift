import XCTest
@testable import Strand

final class DashboardEffortReadoutTests: XCTestCase {
    private let today = "2026-10-03"
    private let yesterday = "2026-10-02"

    func testUncomputedDayDoesNotBorrowYesterdayOrInventZero() {
        let readout = DashboardEffortReadout.resolve(day: today, storedDay: yesterday, stored: 1.3,
            live: .init(day: yesterday, value: 5), currentDay: today)
        XCTAssertEqual(readout.day, today)
        XCTAssertNil(readout.value)
        XCTAssertNil(readout.point)
    }

    func testLiveScoreAndStoredFloorShareTheSelectedDay() throws {
        let live = DashboardEffortReadout(day: today, value: 12)
        let readout = DashboardEffortReadout.resolve(day: today, storedDay: today, stored: 8,
                                                    live: live, currentDay: today)
        XCTAssertEqual(readout.value, 12)
        XCTAssertEqual(try XCTUnwrap(readout.point).value, readout.value)
        let floor = DashboardEffortReadout.resolve(day: today, storedDay: today, stored: 16,
                                                   live: live, currentDay: today)
        XCTAssertEqual(floor.value, 16)
    }

    func testPastDayAndRolloverCannotUseLiveScore() {
        let past = DashboardEffortReadout.resolve(day: yesterday, storedDay: yesterday, stored: 7,
            live: .init(day: today, value: 20), currentDay: today)
        XCTAssertEqual(past.value, 7)
        let rolled = DashboardEffortReadout.resolve(day: yesterday, storedDay: yesterday, stored: 7,
            live: .init(day: yesterday, value: 20), currentDay: today)
        XCTAssertEqual(rolled.value, 7)
    }

    func testNavigatedPastDayRejectsLiveEvenBeforeTheClockRefreshes() {
        let readout = DashboardEffortReadout.resolve(day: yesterday, storedDay: yesterday, stored: 7,
            live: .init(day: yesterday, value: 20), currentDay: yesterday, isToday: false)
        XCTAssertEqual(readout.value, 7)
    }

    func testRealComputedZeroIsPreserved() {
        let readout = DashboardEffortReadout.resolve(day: today, storedDay: nil, stored: nil,
            live: .init(day: today, value: 0), currentDay: today)
        XCTAssertEqual(readout.value, 0)
        XCTAssertEqual(readout.point?.day, today)
    }

    func testNavigationPreservesAnExplicitlyMissingReadout() {
        let missing = DashboardEffortReadout(day: today, value: nil)
        let route = TabRoute.effort(missing)
        guard case .effort(let detail) = route else { return XCTFail("Wrong destination") }
        XCTAssertEqual(detail.day, today)
        XCTAssertNil(detail.point)
    }
}
