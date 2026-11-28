import XCTest
import StrandCore
import WhoopStore
@testable import NoopCore

final class CoreWidgetsTests: XCTestCase {
    func testUsualIsMeanPlusMinusOneDeviationFromSevenValues() throws {
        XCTAssertNil(CoreWidgets.usual([1, 2, 3, nil, 4, 5, 6]), "six values describe a handful of nights, not a band")
        let u = try XCTUnwrap(CoreWidgets.usual([2, 4, 4, 4, 5, 5, 7, 9, nil]))
        XCTAssertEqual(u.low, 3, accuracy: 1e-9)
        XCTAssertEqual(u.high, 7, accuracy: 1e-9)
    }

    func testTheTrainingWeekStartsOnTheCalendarsFirstDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        cal.firstWeekday = 2
        let saturday = cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9))!
        let week = CoreWidgets.trainingWeek(containing: saturday, calendar: cal)
        XCTAssertEqual(week.keys.first, "2026-11-23")
        XCTAssertEqual(week.keys.last, "2026-11-29")
        XCTAssertEqual(week.todayIndex, 5)
        XCTAssertEqual(CoreWidgets.dayKeys(endingAt: saturday, count: 3, calendar: cal), ["2026-11-26", "2026-11-27", "2026-11-28"])
    }

    @MainActor
    func testTheFitnessCallAnswersOnAnEmptyStore() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let json = await CoreWidgets.fitness([:], reader: reader)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((o["days"] as? [String])?.count, 14)
        XCTAssertEqual((o["activeDays"] as? [Any])?.count, 84)
        XCTAssertNotNil(o["workouts"])
    }
}
