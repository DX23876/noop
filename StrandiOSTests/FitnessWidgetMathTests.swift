#if os(iOS)
import XCTest
@testable import NOOP_Staging

final class FitnessWidgetMathTests: XCTestCase {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        berlin.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    func testUsualIsMeanPlusMinusOneStandardDeviation() throws {
        let usual = try XCTUnwrap(FitnessWidgetMath.usual([2, 4, 4, 4, 5, 5, 7, 9, nil]))
        // Mean 5, population standard deviation 2.
        XCTAssertEqual(usual.low, 3, accuracy: 1e-9)
        XCTAssertEqual(usual.high, 7, accuracy: 1e-9)
    }

    func testUsualNeedsSevenValues() {
        XCTAssertNil(FitnessWidgetMath.usual([60, 61, 62, 63, 64, 65, nil, nil]))
        XCTAssertNotNil(FitnessWidgetMath.usual([60, 61, 62, 63, 64, 65, 66]))
    }

    func testDayKeysEndAtTodayOldestFirstAcrossTheClockChange() {
        // 25 October 2026 is the night the clocks go back in Berlin (a 25-hour day).
        let keys = FitnessWidgetMath.dayKeys(endingAt: date(2026, 10, 26, hour: 0), count: 3, calendar: berlin)
        XCTAssertEqual(keys, ["2026-10-24", "2026-10-25", "2026-10-26"])
    }

    func testWeekFollowsTheCalendarsFirstWeekday() {
        var monday = berlin
        monday.firstWeekday = 2
        let week = FitnessWidgetMath.week(containing: date(2026, 10, 7), calendar: monday)
        XCTAssertEqual(week.keys.first, "2026-10-05")
        XCTAssertEqual(week.keys.last, "2026-10-11")
        XCTAssertEqual(week.todayIndex, 2)

        var sunday = berlin
        sunday.firstWeekday = 1
        let sundayWeek = FitnessWidgetMath.week(containing: date(2026, 10, 7), calendar: sunday)
        XCTAssertEqual(sundayWeek.keys.first, "2026-10-04")
        XCTAssertEqual(sundayWeek.todayIndex, 3)
    }

    func testChangeIsLatestMinusEarliest() {
        XCTAssertEqual(FitnessWidgetMath.change([93.7, 93.9, 93.37])!, -0.33, accuracy: 1e-9)
        XCTAssertNil(FitnessWidgetMath.change([93.4]))
    }

    func testLinksLeadToTheScreensTheTodayCardsOpen() {
        XCTAssertEqual(FitnessWidgetLink(url: URL(string: "noop://sleep")!), .sleep)
        XCTAssertEqual(FitnessWidgetLink(url: URL(string: "noop://metric/hrv")!), .detail(.metric("hrv")))
        XCTAssertEqual(FitnessWidgetLink(url: URL(string: "noop://weight")!), .detail(.weight))
        XCTAssertEqual(FitnessWidgetLink(url: URL(string: "noop://workouts")!), .detail(.workouts))
        XCTAssertEqual(FitnessWidgetLink(url: URL(string: "noop://trainingLoad")!), .detail(.trainingLoad))
        XCTAssertEqual(FitnessWidgetLink(url: URL(string: "noop://health")!), .detail(.health))
        XCTAssertNil(FitnessWidgetLink(url: URL(string: "noop://metric")!))
        XCTAssertNil(FitnessWidgetLink(url: URL(string: "noop://goals")!))
    }

    func testSnapshotSaveSkipsAnUnchangedPayload() {
        let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName)
        let stored = defaults?.data(forKey: FitnessWidgetSnapshot.storageKey)
        defer { defaults?.set(stored, forKey: FitnessWidgetSnapshot.storageKey) }
        defaults?.removeObject(forKey: FitnessWidgetSnapshot.storageKey)
        var snapshot = FitnessWidgetSnapshot.placeholder
        XCTAssertTrue(snapshot.save())
        snapshot.updated = snapshot.updated.addingTimeInterval(600)
        XCTAssertFalse(snapshot.save(), "only the time changed")
        snapshot.stepsGoal = (snapshot.stepsGoal ?? 0) + 1
        XCTAssertTrue(snapshot.save())
    }
}
#endif
