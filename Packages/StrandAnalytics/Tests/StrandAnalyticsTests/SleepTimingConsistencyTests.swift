import XCTest
@testable import StrandAnalytics

final class SleepTimingConsistencyTests: XCTestCase {

    private let day = 86_400
    private let hour = 3_600

    /// Sleep 23:00–07:00 on `nights` consecutive nights; the last one wakes at `lastWake`.
    private func nightly(_ nights: Int, lastWake: Int, shiftLastBy: Int = 0) -> [SleepTimingConsistency.Interval] {
        (0..<nights).map { k in
            let wake = lastWake - (nights - 1 - k) * day
            let shift = k == nights - 1 ? shiftLastBy : 0
            return .init(start: wake - 8 * hour + shift, end: wake + shift)
        }
    }

    func testIdenticalScheduleIs100() {
        let wake = 100 * day + 7 * hour
        XCTAssertEqual(SleepTimingConsistency.score(sleeps: nightly(6, lastWake: wake), wakeAt: wake)!, 100,
                       accuracy: 1e-9)
    }

    /// Last night one hour later than the four before: 120 of 1440 minutes disagree with each previous day,
    /// agreement 0.9167, on the SRI scale 200·a − 100 = 83.33.
    func testOneHourShiftMatchesHandComputation() {
        let wake = 100 * day + 7 * hour
        let sleeps = nightly(6, lastWake: wake, shiftLastBy: hour)
        XCTAssertEqual(SleepTimingConsistency.score(sleeps: sleeps, wakeAt: wake + hour)!, 83.333, accuracy: 0.01)
    }

    /// Naps count: the same nap only on the last day lowers the score.
    func testNapsCount() {
        let wake = 100 * day + 7 * hour
        var sleeps = nightly(6, lastWake: wake + day)
        sleeps.append(.init(start: wake + 7 * hour, end: wake + 8 * hour))   // 14:00–15:00 on the last day
        let withNap = SleepTimingConsistency.score(sleeps: sleeps, wakeAt: wake + day)!
        XCTAssertLessThan(withNap, 100)
        XCTAssertEqual(withNap, 200 * (1 - 60.0 / 1440) - 100, accuracy: 1e-9)
    }

    /// Wildly irregular sleep floors at 0 rather than going negative like the raw SRI can.
    func testFloorsAtZero() {
        let wake = 100 * day + 7 * hour
        var sleeps: [SleepTimingConsistency.Interval] = [.init(start: wake - 8 * hour, end: wake)]
        for k in 1...4 { sleeps.append(.init(start: wake - k * day + 4 * hour, end: wake - k * day + 12 * hour + k * 600)) }
        let s = SleepTimingConsistency.score(sleeps: sleeps, wakeAt: wake)!
        XCTAssertGreaterThanOrEqual(s, 0)
        XCTAssertLessThan(s, 60)
    }

    /// No sleep inside the last 24 h means there is nothing to compare.
    func testNilWithoutSleepInLastDay() {
        let wake = 100 * day + 7 * hour
        XCTAssertNil(SleepTimingConsistency.score(sleeps: nightly(3, lastWake: wake - 2 * day), wakeAt: wake))
    }

    /// Every night ending in the range is scored from its fifth recorded night on; a nap does not become the
    /// main sleep, and a gap night resets the four-night lead-in.
    func testScoresByDayNeedsFourPriorNights() {
        let day0 = 1_790_000_000 - 1_790_000_000 % 86_400   // a UTC midnight
        func night(_ i: Int) -> SleepTimingConsistency.Interval {
            .init(start: day0 + i * 86_400 - 3_600, end: day0 + i * 86_400 + 6 * 3_600)
        }
        let nap = SleepTimingConsistency.Interval(start: day0 + 6 * 86_400 + 14 * 3_600,
                                                  end: day0 + 6 * 86_400 + 14 * 3_600 + 1_200)
        var sessions = (0..<10).filter { $0 != 8 }.map(night) + [nap]
        sessions.sort { $0.start < $1.start }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        func key(_ ts: Int) -> String { fmt.string(from: Date(timeIntervalSince1970: Double(ts))) }
        let scores = SleepTimingConsistency.scoresByDay(sessions: sessions, from: day0, to: day0 + 10 * 86_400,
                                                        offsetSec: 0, dayOf: key)
        XCTAssertEqual(Set(scores.keys), Set([4, 5, 6, 7].map { key(day0 + $0 * 86_400) }))
        XCTAssertEqual(scores[key(day0 + 4 * 86_400)] ?? 0, 100, accuracy: 1e-9)
        XCTAssertLessThan(scores[key(day0 + 7 * 86_400)] ?? 100, 100, "the afternoon nap falls in the next night's 24 h")
    }

    /// A night split by an hour awake (the reinmaker/noop #76 shape: 01:57 to 06:26, then 07:30 to 10:23)
    /// is scored at its real wake, not at the end of its longer first fragment.
    func testScoresByDayScoresASplitNightAtItsLastWake() {
        let day0 = 1_790_000_000 - 1_790_000_000 % 86_400   // a UTC midnight
        var sessions = (0..<5).map { k -> SleepTimingConsistency.Interval in
            .init(start: day0 + k * day + 2 * hour, end: day0 + k * day + 10 * hour + 23 * 60)
        }
        let last = day0 + 5 * day
        let first = SleepTimingConsistency.Interval(start: last + hour + 57 * 60, end: last + 6 * hour + 26 * 60)
        let second = SleepTimingConsistency.Interval(start: last + 7 * hour + 30 * 60, end: last + 10 * hour + 23 * 60)
        sessions += [first, second]
        let scores = SleepTimingConsistency.scoresByDay(sessions: sessions, from: last, to: last + day,
                                                        offsetSec: 0) { _ in "last" }
        let atWake = SleepTimingConsistency.score(sleeps: sessions, wakeAt: second.end)!
        let atFirstFragment = SleepTimingConsistency.score(sleeps: sessions, wakeAt: first.end)!
        XCTAssertNotEqual(atWake, atFirstFragment, accuracy: 1, "the scenario must tell the two anchors apart")
        XCTAssertEqual(scores["last"] ?? -1, atWake, accuracy: 1e-9)
    }
}
