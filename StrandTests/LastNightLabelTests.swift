import XCTest
@testable import Strand

/// "Last night" names only the night that woke on today's logical day (design critique 2026-11-28). The
/// newest stored night is older while the strap has not synced, and the Sleep tab called it "Last night"
/// right under a banner waiting for last night. Twin of the Kotlin `LastNightTest`.
final class LastNightLabelTests: XCTestCase {
    private let cal = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func ts(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    func testANightThatWokeThisMorningIsLastNight() {
        let wake = date(2026, 11, 28, 7, 15)
        XCTAssertTrue(Repository.isLastNight(endTs: ts(wake), now: date(2026, 11, 28, 14, 0)))
    }

    func testTheNightBeforeIsNotLastNight() {
        // Saturday afternoon, the newest stored night woke on Friday: the strap has not synced yet.
        let wake = date(2026, 11, 27, 7, 37)
        XCTAssertFalse(Repository.isLastNight(endTs: ts(wake), now: date(2026, 11, 28, 14, 0)))
    }

    func testInTheSmallHoursYesterdaysNightIsStillLastNight() {
        // 01:30 on Sunday is still Saturday's logical day, so Saturday morning's night stays last night.
        let wake = date(2026, 11, 28, 7, 15)
        XCTAssertTrue(Repository.isLastNight(endTs: ts(wake), now: date(2026, 11, 29, 1, 30)))
        XCTAssertFalse(Repository.isLastNight(endTs: ts(wake), now: date(2026, 11, 29, 4, 30)))
    }

    func testAWakeBeforeTheRolloverCountsForItsCalendarDay() {
        // Woke at 03:00 on Saturday: the stored row is Saturday's, so it is last night all Saturday.
        let wake = date(2026, 11, 28, 3, 0)
        XCTAssertTrue(Repository.isLastNight(endTs: ts(wake), now: date(2026, 11, 28, 20, 0)))
    }
}
