import XCTest
@testable import StrandAnalytics

final class StreakCalculatorTests: XCTestCase {

    private let today = "2026-07-24"

    private func expect(_ dayKeys: [String], _ qualified: [Bool], current: Int, longest: Int,
                        today: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let got = StreakCalculator.streaks(dayKeys: dayKeys, qualified: qualified, today: today ?? self.today)
        XCTAssertEqual(got, StreakCalculator.Streaks(current: current, longest: longest), file: file, line: line)
    }

    func testEmptyHistory() {
        expect([], [], current: 0, longest: 0)
    }

    func testSingleDayToday() {
        expect(["2026-07-24"], [true], current: 1, longest: 1)
    }

    func testUnbrokenRunEndingToday() {
        expect(["2026-07-20", "2026-07-21", "2026-07-22", "2026-07-23", "2026-07-24"],
               [true, true, true, true, true], current: 5, longest: 5)
    }

    func testGapResetsCurrentButKeepsLongest() {
        // A 3-day run in the past, then a 2-day run ending today: current follows the recent run.
        expect(["2026-07-10", "2026-07-11", "2026-07-12", "2026-07-23", "2026-07-24"],
               [true, true, true, true, true], current: 2, longest: 3)
    }

    func testTodayNotYetScoredGrace() {
        // Today (2026-07-24) has no record yet; the run ending YESTERDAY still counts as current.
        expect(["2026-07-21", "2026-07-22", "2026-07-23"], [true, true, true], current: 3, longest: 3)
    }

    func testMissedYesterdayAndTodayBreaksCurrent() {
        // Newest qualifying day is 2 days before today -> current is 0, longest still stands.
        expect(["2026-07-20", "2026-07-21", "2026-07-22"], [true, true, true], current: 0, longest: 3)
    }

    func testDuplicateDayKeysDeduped() {
        expect(["2026-07-24", "2026-07-24"], [true, true], current: 1, longest: 1)
    }

    func testLongestRunInTheMiddleOfHistory() {
        expect(["2026-07-01", "2026-07-02", "2026-07-03", "2026-07-04", "2026-07-05",
                "2026-07-23", "2026-07-24"], Array(repeating: true, count: 7), current: 2, longest: 5)
    }

    func testUnqualifiedDayBreaksTheRun() {
        // 2026-07-23 is present but NOT qualified, so the run ending today is just today.
        expect(["2026-07-22", "2026-07-23", "2026-07-24"], [true, false, true], current: 1, longest: 1)
    }

    func testMismatchedArrayLengthsUseThePairedPrefix() {
        expect(["2026-07-24", "2026-07-23"], [true], current: 1, longest: 1)
    }

    func testUnparseableTodayYieldsNoCurrentButKeepsLongest() {
        expect(["2026-07-23", "2026-07-24"], [true, true], current: 0, longest: 2, today: "not-a-date")
    }
}
