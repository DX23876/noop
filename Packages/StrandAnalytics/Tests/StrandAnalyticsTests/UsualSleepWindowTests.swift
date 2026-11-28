import XCTest
@testable import StrandAnalytics

final class UsualSleepWindowTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    /// 2026-11-01 00:00 UTC.
    private let day0 = 1_793_491_200

    private func night(_ index: Int, from startHour: Double, hours: Double) -> (start: Int, end: Int) {
        let start = day0 + index * 86_400 + Int(startHour * 3_600)
        return (start, start + Int(hours * 3_600))
    }

    func testAWindowThatSpansMidnightResolvesFromTheMedianNight() {
        let nights = (0..<10).map { night($0, from: 23 + Double($0 % 3) * 0.5, hours: 8) }
        let window = UsualSleepWindow.resolve(nights: nights, endingBy: day0 + 20 * 86_400, calendar: calendar)
        XCTAssertEqual(window.startMinute, 23 * 60 + 30)
        XCTAssertEqual(window.endMinute, 7 * 60 + 30)
        XCTAssertTrue(window.contains(minute: 2 * 60))
        XCTAssertTrue(window.contains(minute: 23 * 60 + 45))
        XCTAssertFalse(window.contains(minute: 12 * 60))
    }

    /// A night-shift worker sleeping from eight to four in the day.
    func testADaySleepersWindowResolves() {
        let nights = (0..<7).map { night($0, from: 8, hours: 8) }
        let window = UsualSleepWindow.resolve(nights: nights, endingBy: day0 + 20 * 86_400, calendar: calendar)
        XCTAssertEqual(window, UsualSleepWindow(startMinute: 8 * 60, endMinute: 16 * 60))
        XCTAssertTrue(window.contains(minute: 12 * 60))
        XCTAssertFalse(window.contains(minute: 2 * 60))
    }

    func testTooFewNightsFallBackToElevenToSeven() {
        let nights = [night(0, from: 1, hours: 8), night(1, from: 1, hours: 8)]
        XCTAssertEqual(UsualSleepWindow.resolve(nights: nights, endingBy: day0 + 5 * 86_400, calendar: calendar),
                       .fallback)
    }

    /// Naps do not move the window, and only the longest night per wake day counts.
    func testNapsAndShortSegmentsAreIgnored() {
        var nights = (0..<5).map { night($0, from: 22, hours: 8) }
        nights += (0..<5).map { night($0, from: 14, hours: 1) }
        let window = UsualSleepWindow.resolve(nights: nights, endingBy: day0 + 20 * 86_400, calendar: calendar)
        XCTAssertEqual(window, UsualSleepWindow(startMinute: 22 * 60, endMinute: 6 * 60))
    }

    /// A day is never priced with nights that ended after it.
    func testNightsAfterTheCutoffAreNotRead() {
        let early = (0..<5).map { night($0, from: 22, hours: 8) }
        let late = (10..<15).map { night($0, from: 2, hours: 8) }
        let cutoff = day0 + 6 * 86_400
        XCTAssertEqual(UsualSleepWindow.resolve(nights: early + late, endingBy: cutoff, calendar: calendar),
                       UsualSleepWindow(startMinute: 22 * 60, endMinute: 6 * 60))
    }

    func testAwakeSecondsCountOnlyTimeOutsideTheWindow() {
        let window = UsualSleepWindow(startMinute: 23 * 60, endMinute: 7 * 60)
        let wholeDay = window.awakeSeconds(from: day0, to: day0 + 86_400, calendar: calendar)
        XCTAssertEqual(wholeDay, 16 * 3_600)
        let evening = window.awakeSeconds(from: day0 + 22 * 3_600, to: day0 + 24 * 3_600, calendar: calendar)
        XCTAssertEqual(evening, 3_600)
    }
}
