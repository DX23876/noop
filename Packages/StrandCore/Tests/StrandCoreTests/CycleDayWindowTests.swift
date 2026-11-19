import Foundation
import StrandAnalytics
import WhoopStore
import XCTest
@testable import StrandCore

/// The span the day in progress is measured over (`CycleDayWindow`).
///
/// The tester report of 2026-11-19: asleep 04:41, awake 13:19, Effort at 47 on waking without getting out
/// of bed. In sleep-onset mode the day starts at the onset, so his waking hours between midnight and 04:41
/// are the previous cycle's — but the live score and the today refresh both ran from local midnight and
/// counted them again, and the stored floor kept the result up.
final class CycleDayWindowTests: XCTestCase {

    private let offset = 7 * 3_600          // GMT+07:00, the reporter's zone
    private func ts(_ text: String) -> Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(secondsFromGMT: offset)
        f.locale = Locale(identifier: "en_US_POSIX")
        return Int(f.date(from: text)!.timeIntervalSince1970)
    }

    private func night(onset: String, wake: String) -> CachedSleepSession {
        CachedSleepSession(startTs: ts(onset), endTs: ts(wake), efficiency: nil, restingHr: nil,
                           avgHrv: nil, stagesJSON: nil)
    }

    // MARK: The window

    func testSleepOnsetModeStartsTheDayWhereTheWearerFellAsleep() {
        let now = ts("2026-11-19 13:58")
        let cycle = CycleDayWindow.Cycle(onset: ts("2026-11-19 04:41"), wakeDay: "2026-11-19")
        let window = CycleDayWindow.window(mode: .sleepOnset, cycle: cycle, now: now, offsetSec: offset)
        XCTAssertEqual(window.from, ts("2026-11-19 04:41"))
        XCTAssertEqual(window.to, now)
        // The hours this is all about: awake, before bed, and NOT in this day's window.
        XCTAssertGreaterThan(ts("2026-11-19 02:00"), CycleDayWindow.window(
            mode: .midnight, cycle: cycle, now: now, offsetSec: offset).from)
        XCTAssertLessThan(ts("2026-11-19 02:00"), window.from)
    }

    func testMidnightModeIsTheCalendarDayWhateverTheCycleSays() {
        let now = ts("2026-11-19 13:58")
        let cycle = CycleDayWindow.Cycle(onset: ts("2026-11-19 04:41"), wakeDay: "2026-11-19")
        let window = CycleDayWindow.window(mode: .midnight, cycle: cycle, now: now, offsetSec: offset)
        XCTAssertEqual(window.from, ts("2026-11-19 00:00"))
    }

    func testWithoutACycleTheCalendarDayStands() {
        let now = ts("2026-11-19 13:58")
        let window = CycleDayWindow.window(mode: .sleepOnset, cycle: nil, now: now, offsetSec: offset)
        XCTAssertEqual(window.from, ts("2026-11-19 00:00"))
    }

    /// A cycle nobody closed does not grow without end: past `absoluteMaxOpenSeconds` the resolver falls
    /// back to a synthetic midnight, exactly as it does for the pass.
    func testACycleLeftOpenTooLongFallsBackToMidnight() {
        let onset = ts("2026-11-17 04:41")
        let now = ts("2026-11-19 13:58")       // more than 40 hours later
        let cycle = CycleDayWindow.Cycle(onset: onset, wakeDay: "2026-11-17")
        let window = CycleDayWindow.window(mode: .sleepOnset, cycle: cycle, now: now, offsetSec: offset)
        XCTAssertGreaterThan(window.from, onset)
        XCTAssertEqual(CycleDayWindow.day(mode: .sleepOnset, cycle: cycle, now: now, offsetSec: offset),
                       "2026-11-19", "a stale cycle does not keep filing figures under its own wake day")
    }

    // MARK: Which cycle the wearer is in

    func testTheStoredOnsetIsUsedWhenThePassHasSeenTheNight() {
        let now = ts("2026-11-19 13:58")
        let onsets = [MetricPoint(day: "2026-11-19", key: DayCycleIntelligenceIntegration.onsetKey,
                                  value: Double(ts("2026-11-19 04:41")))]
        let cycle = CycleDayWindow.current(onsets: onsets, sleeps: [], now: now, offsetSec: offset)
        XCTAssertEqual(cycle, CycleDayWindow.Cycle(onset: ts("2026-11-19 04:41"), wakeDay: "2026-11-19"))
    }

    /// The morning after a night no pass has seen is exactly when a live figure matters, so the stored
    /// night answers for it.
    func testANightThePassHasNotSeenYetStillOpensTheDay() {
        let now = ts("2026-11-19 13:58")
        let onsets = [MetricPoint(day: "2026-11-18", key: DayCycleIntelligenceIntegration.onsetKey,
                                  value: Double(ts("2026-11-18 03:10")))]
        let sleeps = [night(onset: "2026-11-19 04:41", wake: "2026-11-19 13:19")]
        let cycle = CycleDayWindow.current(onsets: onsets, sleeps: sleeps, now: now, offsetSec: offset)
        XCTAssertEqual(cycle, CycleDayWindow.Cycle(onset: ts("2026-11-19 04:41"), wakeDay: "2026-11-19"))
    }

    /// A night still running belongs to the next cycle. Rolling the day the moment the wearer falls
    /// asleep would empty the evening out of the figure they last looked at.
    func testANightInProgressDoesNotRollTheDay() {
        let now = ts("2026-11-19 23:30")
        let sleeps = [night(onset: "2026-11-19 04:41", wake: "2026-11-19 13:19"),
                      CachedSleepSession(startTs: ts("2026-11-19 23:10"), endTs: ts("2026-11-20 07:00"),
                                         efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)]
        let cycle = CycleDayWindow.current(onsets: [], sleeps: sleeps, now: now, offsetSec: offset)
        XCTAssertEqual(cycle?.onset, ts("2026-11-19 04:41"))
    }

    func testAnOnsetOlderThanTheLookbackIsNotACycle() {
        let now = ts("2026-11-19 13:58")
        let sleeps = [night(onset: "2026-11-10 23:00", wake: "2026-11-11 07:00")]
        XCTAssertNil(CycleDayWindow.current(onsets: [], sleeps: sleeps, now: now, offsetSec: offset))
    }

    /// The day a figure is filed under is the cycle's wake day, not the calendar day the clock happens to
    /// show: at 01:00, still up from yesterday, the figure belongs to yesterday.
    func testTheDayIsTheCyclesWakeDay() {
        let now = ts("2026-11-20 01:00")
        let cycle = CycleDayWindow.Cycle(onset: ts("2026-11-19 04:41"), wakeDay: "2026-11-19")
        XCTAssertEqual(CycleDayWindow.day(mode: .sleepOnset, cycle: cycle, now: now, offsetSec: offset),
                       "2026-11-19")
        XCTAssertEqual(CycleDayWindow.day(mode: .midnight, cycle: cycle, now: now, offsetSec: offset),
                       "2026-11-20")
    }
}
