import XCTest
@testable import Strand
import StrandAnalytics

/// What the "add a sleep" pickers open with (2026-11-20).
///
/// Two fields starting at zero are unusable, and the right seed is not the same on every day: a day with
/// no main sleep is almost always a night the detector missed, a day that has one is almost always a nap.
@MainActor
final class AddSleepSeedTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testADayWithoutASleepSeedsTheNight() {
        let day = date(2026, 11, 20, 13)
        let seed = SleepNightEditor.addSeed(dayStart: day, hasMainSleep: false,
                                            now: date(2026, 11, 20, 13), calendar: calendar)
        XCTAssertEqual(seed.bedTs, Int(date(2026, 11, 19, 23).timeIntervalSince1970))
        XCTAssertEqual(seed.wakeTs, Int(date(2026, 11, 20, 7).timeIntervalSince1970))
    }

    func testADayThatAlreadyHasASleepSeedsANap() {
        let now = date(2026, 11, 20, 15, 30)
        let seed = SleepNightEditor.addSeed(dayStart: now, hasMainSleep: true, now: now, calendar: calendar)
        XCTAssertEqual(seed.wakeTs, Int(now.timeIntervalSince1970))
        XCTAssertEqual(seed.wakeTs - seed.bedTs, 3600)
    }

    /// A sleep cannot end in the future, and `clampedEditWindow` would refuse a seed that did.
    func testTheNightSeedNeverReachesIntoTheFuture() {
        let now = date(2026, 11, 20, 5, 15)
        let seed = SleepNightEditor.addSeed(dayStart: now, hasMainSleep: false, now: now, calendar: calendar)
        XCTAssertEqual(seed.wakeTs, Int(now.timeIntervalSince1970))
        XCTAssertEqual(seed.bedTs, Int(date(2026, 11, 19, 23).timeIntervalSince1970))
        XCTAssertNotNil(SleepEditGuard.clampedEditWindow(start: seed.bedTs, end: seed.wakeTs,
                                                         now: Int(now.timeIntervalSince1970)))
    }

    /// Just past midnight the night seed would be minutes long, which is not what anybody meant.
    func testJustAfterMidnightItFallsBackToTheLastHour() {
        let now = date(2026, 11, 20, 0, 10)
        let seed = SleepNightEditor.addSeed(dayStart: now, hasMainSleep: false, now: now, calendar: calendar)
        XCTAssertEqual(seed.wakeTs - seed.bedTs, 3600)
        XCTAssertEqual(seed.wakeTs, Int(now.timeIntervalSince1970))
    }
}
