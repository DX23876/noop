import XCTest
@testable import StrandAnalytics

final class GoalMotivationTests: XCTestCase {

    private func days(from start: String, _ values: [Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        var day = start
        for value in values {
            result[day] = value
            day = WeeklyDigestEngine.addDays(day, 1)
        }
        return result
    }

    // MARK: Streaks

    func testStreakCountsDaysInARowEndingYesterdayWhileTodayIsOpen() {
        // 1–5 Oct met, today (6 Oct) still below target: the run stands at 5, not 0.
        let values = days(from: "2026-10-01", [10_500, 11_000, 12_000, 10_000, 10_200, 3_000])
        let s = GoalMotivation.streak(values: values, target: 10_000, firstDay: "2026-10-01", today: "2026-10-06")
        XCTAssertEqual(s.current, 5)
        XCTAssertEqual(s.best, 5)
    }

    func testStreakIncludesTodayOnceItIsMet() {
        let values = days(from: "2026-10-01", [10_500, 11_000, 12_500])
        let s = GoalMotivation.streak(values: values, target: 10_000, firstDay: "2026-10-01", today: "2026-10-03")
        XCTAssertEqual(s.current, 3)
    }

    func testAMissedDayResetsAndBestKeepsTheLongerRun() {
        let values = days(from: "2026-10-01", [10_000, 10_000, 10_000, 4_000, 10_000, 10_000])
        let s = GoalMotivation.streak(values: values, target: 10_000, firstDay: "2026-10-01", today: "2026-10-06")
        XCTAssertEqual(s.current, 2)
        XCTAssertEqual(s.best, 3)
        XCTAssertEqual(s.firstReached, ["2026-10-01", "2026-10-02", "2026-10-03"])
    }

    func testADayWithoutDataBreaksTheRun() {
        var values = days(from: "2026-10-01", [10_000, 10_000])
        values["2026-10-04"] = 10_000   // 3 Oct has no reading at all
        let s = GoalMotivation.streak(values: values, target: 10_000, firstDay: "2026-10-01", today: "2026-10-04")
        XCTAssertEqual(s.current, 1)
        XCTAssertEqual(s.best, 2)
    }

    func testUnscheduledDaysNeitherCountNorBreak() {
        // 3 Oct is a day the goal does not ask for; the run goes on across it.
        let values = days(from: "2026-10-01", [10_000, 10_000, 0, 10_000])
        let s = GoalMotivation.streak(values: values, target: 10_000, firstDay: "2026-10-01", today: "2026-10-04",
                                      isScheduled: { $0 != "2026-10-03" })
        XCTAssertEqual(s.current, 3)
    }

    // MARK: Badges

    func testDailyAndLifetimeStepBadgesCarryTheDayTheyWereEarned() {
        let steps = ["2026-09-01": 60_000, "2026-09-02": 16_000, "2026-09-03": 30_000]
        let badges = GoalMotivation.badges(stepsByDay: steps, stepStreak: nil, reachedWeeks: [], workoutDays: [])
        func earned(_ family: GoalMotivation.BadgeFamily, _ threshold: Int) -> String? {
            badges.first { $0.family == family && $0.threshold == threshold }?.earnedOn
        }
        XCTAssertEqual(earned(.dailySteps, 15_000), "2026-09-01")
        XCTAssertEqual(earned(.dailySteps, 40_000), "2026-09-01")
        XCTAssertEqual(earned(.lifetimeSteps, 100_000), "2026-09-03")   // 60k + 16k + 30k = 106k
        XCTAssertNil(earned(.lifetimeSteps, 250_000))
    }

    func testStreakWeeksAndWorkoutBadgesCountInOrder() {
        let streak = GoalMotivation.Streak(current: 3, best: 3, firstReached: ["2026-10-01", "2026-10-02", "2026-10-03"])
        let workouts = (1...12).map { String(format: "2026-08-%02d", $0) }
        let badges = GoalMotivation.badges(stepsByDay: [:], stepStreak: streak,
                                           reachedWeeks: ["2026-09-13", "2026-09-06"], workoutDays: workouts.reversed())
        XCTAssertEqual(badges.first { $0.id == "stepStreak.3" }?.earnedOn, "2026-10-03")
        XCTAssertNil(badges.first { $0.id == "stepStreak.7" }?.earnedOn)
        XCTAssertEqual(badges.first { $0.id == "weeksReached.1" }?.earnedOn, "2026-09-06")
        XCTAssertEqual(badges.first { $0.id == "workouts.10" }?.earnedOn, "2026-08-10")
    }

    func testNextBadgeMeasuresFromThePreviousLevel() {
        let badges = GoalMotivation.badges(stepsByDay: ["2026-09-01": 12_000], stepStreak: nil,
                                           reachedWeeks: [], workoutDays: [])
        let next = GoalMotivation.nextBadge(in: .dailySteps, badges: badges, progressValue: 12_500)
        XCTAssertEqual(next?.badge.threshold, 15_000)
        XCTAssertEqual(next?.fraction ?? 0, 0.5, accuracy: 0.0001)   // 10k → 15k, at 12.5k
    }

    // MARK: Records

    func testRecordsPickTheBestDayWeekAndWorkoutWeek() {
        // Monday-start weeks: 28 Sep and 5 Oct.
        let steps = ["2026-09-28": 8_000, "2026-09-29": 14_000, "2026-10-05": 13_000, "2026-10-06": 12_000]
        let workouts = ["2026-09-28", "2026-10-05", "2026-10-06", "2026-10-07"]
        let r = GoalMotivation.records(stepsByDay: steps, workoutDays: workouts, firstWeekday: 2, longestStepStreak: 4)
        XCTAssertEqual(r.bestStepDay?.day, "2026-09-29")
        XCTAssertEqual(r.bestStepWeek?.start, "2026-10-05")
        XCTAssertEqual(r.bestStepWeek?.steps, 25_000)
        XCTAssertEqual(r.mostWorkoutsWeek?.start, "2026-10-05")
        XCTAssertEqual(r.mostWorkoutsWeek?.count, 3)
        XCTAssertEqual(r.longestStepStreak, 4)
    }

    func testANewRecordMustBeatEveryEarlierDay() {
        XCTAssertTrue(GoalMotivation.isNewStepRecord(stepsByDay: ["2026-10-01": 9_000, "2026-10-02": 9_500],
                                                     today: "2026-10-02"))
        XCTAssertFalse(GoalMotivation.isNewStepRecord(stepsByDay: ["2026-10-01": 9_500, "2026-10-02": 9_500],
                                                      today: "2026-10-02"))
        XCTAssertFalse(GoalMotivation.isNewStepRecord(stepsByDay: ["2026-10-02": 9_500], today: "2026-10-02"))
    }
}
