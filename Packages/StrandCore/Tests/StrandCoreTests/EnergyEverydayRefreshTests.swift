import XCTest
import StrandAnalytics
@testable import StrandCore

/// The awake time no bucket represented (strap off for a shower, no data during the day) takes the
/// everyday allowance; detected sleep and the usual sleep window do not (owner decisions Q7, Q32).
final class EnergyEverydayRefreshTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    /// 2026-11-21 00:00 UTC.
    private let dayFrom = 1_795_219_200

    func testOnlyAwakeUnrepresentedSlotsCount() {
        let window = UsualSleepWindow(startMinute: 23 * 60, endMinute: 7 * 60)
        // Every slot from 07:00 to 23:00 is represented except 12:00 to 13:00.
        let represented = Set(stride(from: dayFrom + 7 * 3_600, to: dayFrom + 23 * 3_600, by: 300)
            .filter { !($0 >= dayFrom + 12 * 3_600 && $0 < dayFrom + 13 * 3_600) })
        let seconds = EnergyModelRefresh.unrepresentedAwakeSeconds(
            from: dayFrom, to: dayFrom + 86_400, represented: represented, sleep: [],
            window: window, calendar: calendar)
        XCTAssertEqual(seconds, 3_600, "the hour without data at noon; the night is inside the window")
    }

    func testDetectedSleepOutsideTheWindowIsNotAwake() {
        let window = UsualSleepWindow(startMinute: 23 * 60, endMinute: 7 * 60)
        let nap = (start: dayFrom + 14 * 3_600, end: dayFrom + 15 * 3_600)
        let seconds = EnergyModelRefresh.unrepresentedAwakeSeconds(
            from: dayFrom + 14 * 3_600, to: dayFrom + 16 * 3_600, represented: [], sleep: [nap],
            window: window, calendar: calendar)
        XCTAssertEqual(seconds, 3_600, "the nap hour is sleep, the hour after it awake")
    }

    func testTodayStopsAtTheGivenEnd() {
        let window = UsualSleepWindow.fallback
        let seconds = EnergyModelRefresh.unrepresentedAwakeSeconds(
            from: dayFrom, to: dayFrom + 9 * 3_600 + 150, represented: [], sleep: [],
            window: window, calendar: calendar)
        XCTAssertEqual(seconds, 2 * 3_600 + 150)
    }
}
