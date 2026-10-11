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
}
