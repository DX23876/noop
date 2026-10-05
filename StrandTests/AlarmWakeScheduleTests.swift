import XCTest
@testable import Strand

/// The Alarms screen's single wake schedule: the strap alarm and the wind-down reminder read one base time
/// (`behavior.smartAlarmMinutes`, mirrored into `WindDownNudge`) and one set of per-day overrides.
///
/// Covers the pure halves: which of the two times older builds stored separately survives the one-time
/// merge, and which day's wake the hero and the reminder line describe.
final class AlarmWakeScheduleTests: XCTestCase {

    /// Fixed UTC calendar so the math is deterministic regardless of the test machine's locale/zone.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-06-17 is a Wednesday (weekday 4). Build a reference "now" at a given hour:minute UTC.
    private func wed(_ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: hour, minute: minute))!
    }

    /// 2026-06-20 is a Saturday (weekday 7).
    private func sat(_ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: hour, minute: minute))!
    }

    // MARK: unifiedWakeMinutes

    /// With the alarm on, its time is the one that wakes the user, so it wins and an armed alarm is never
    /// re-timed by the merge.
    func testMerge_alarmOn_keepsTheAlarmTime() {
        XCTAssertEqual(SmartAlarmView.unifiedWakeMinutes(alarmMinutes: 6 * 60, alarmEnabled: true,
                                                         reminderMinutes: 7 * 60 + 30, reminderEnabled: true), 6 * 60)
        XCTAssertEqual(SmartAlarmView.unifiedWakeMinutes(alarmMinutes: 6 * 60, alarmEnabled: true,
                                                         reminderMinutes: 7 * 60 + 30, reminderEnabled: false), 6 * 60)
    }

    /// Someone who only used the reminder set its time on purpose; adopting the alarm's untouched default
    /// would silently move their reminder.
    func testMerge_onlyReminderOn_keepsTheReminderTime() {
        XCTAssertEqual(SmartAlarmView.unifiedWakeMinutes(alarmMinutes: 7 * 60, alarmEnabled: false,
                                                         reminderMinutes: 6 * 60 + 15, reminderEnabled: true), 6 * 60 + 15)
    }

    func testMerge_bothOff_keepsTheAlarmTime() {
        XCTAssertEqual(SmartAlarmView.unifiedWakeMinutes(alarmMinutes: 8 * 60, alarmEnabled: false,
                                                         reminderMinutes: 9 * 60, reminderEnabled: false), 8 * 60)
    }

    // MARK: nextWakeWeekday

    func testNextWake_beforeTodaysWake_isToday() {
        XCTAssertEqual(SmartAlarmView.nextWakeWeekday(base: 7 * 60, overrides: [:], now: wed(2, 0), calendar: cal), 4)
    }

    /// At the wake minute itself the wake has happened; the next one is tomorrow's.
    func testNextWake_atOrAfterTodaysWake_isTomorrow() {
        XCTAssertEqual(SmartAlarmView.nextWakeWeekday(base: 7 * 60, overrides: [:], now: wed(7, 0), calendar: cal), 5)
        XCTAssertEqual(SmartAlarmView.nextWakeWeekday(base: 7 * 60, overrides: [:], now: wed(22, 0), calendar: cal), 5)
    }

    /// Today's own override decides whether today's wake is still ahead, not the base time.
    func testNextWake_usesTodaysOverride() {
        // Base 07:00 has passed at 08:00, but Wednesday's own 09:30 has not.
        XCTAssertEqual(SmartAlarmView.nextWakeWeekday(base: 7 * 60, overrides: [4: 9 * 60 + 30],
                                                      now: wed(8, 0), calendar: cal), 4)
    }

    func testNextWake_wrapsFromSaturdayToSunday() {
        XCTAssertEqual(SmartAlarmView.nextWakeWeekday(base: 7 * 60, overrides: [:], now: sat(21, 0), calendar: cal), 1)
    }

    // MARK: WindDownNudge.nudgeMinuteOfDay(forWake:)

    /// The explicit-wake form must be the same arithmetic the scheduler uses, wraps included.
    @MainActor
    func testNudgeForWake_matchesTheStoredWakePath() {
        let key = "windDown.wakeMinutes"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        for wake in [0, 3 * 60 + 30, 7 * 60, 13 * 60, 24 * 60 - 1] {
            UserDefaults.standard.set(wake, forKey: key)
            XCTAssertEqual(WindDownNudge.nudgeMinuteOfDay(forWake: wake), WindDownNudge.nudgeMinuteOfDay(), "wake \(wake)")
        }
    }
}
