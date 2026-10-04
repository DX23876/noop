import XCTest
@testable import StrandAnalytics

final class PeriodGoalPaceTests: XCTestCase {

    private func week(_ values: [Double?], rest: Set<Int> = []) -> [PeriodDay] {
        let keys = PeriodCalendar.weekDays(containing: "2026-10-07", firstWeekday: 2)
        return keys.enumerated().map { i, key in
            PeriodDay(key: key, value: i < values.count ? values[i] : 0, isRest: rest.contains(i))
        }
    }

    // MARK: - Count goals

    func testCountOnPaceMidWeek() {
        // 4 runs a week; Mon and Wed done, today is Thursday.
        let r = PeriodGoalPace.evaluate(.init(aggregation: .count, target: 4,
                                              days: week([1, 0, 1, 0]), todayIndex: 3))
        XCTAssertEqual(r.current, 2)
        XCTAssertEqual(r.paceFraction ?? -1, 0.5, accuracy: 1e-9)   // 4 × 3.5/7 = 2.0 of 4
        XCTAssertEqual(r.state, .onTrack)
        XCTAssertEqual(r.remainingDays, 4)
        XCTAssertEqual(r.requiredPerDay ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.projected ?? -1, 4, accuracy: 1e-9)
    }

    func testCountCloseAgainstOwnCapacity() {
        let r = PeriodGoalPace.evaluate(.init(aggregation: .count, target: 4, days: week([1, 0, 0, 0]),
                                              todayIndex: 3, typicalDailyUpper: 1))
        XCTAssertEqual(r.state, .close)
        XCTAssertEqual(r.requiredPerDay ?? -1, 0.75, accuracy: 1e-9)
    }

    func testCountBehindAndOutOfReach() {
        // Saturday, nothing done: 4 still needed over 2 days.
        let behind = PeriodGoalPace.evaluate(.init(aggregation: .count, target: 4,
                                                   days: week([0, 0, 0, 0, 0, 0]), todayIndex: 5))
        XCTAssertEqual(behind.state, .behind)
        // With one per day at most, 4 in 2 days is provably impossible.
        let out = PeriodGoalPace.evaluate(.init(aggregation: .hitDays, target: 4,
                                                days: week([0, 0, 0, 0, 0, 0]), todayIndex: 5, maxPerDay: 1))
        XCTAssertEqual(out.state, .outOfReach)
    }

    func testAheadStartingAndAchieved() {
        let ahead = PeriodGoalPace.evaluate(.init(aggregation: .count, target: 4, days: week([2]), todayIndex: 0))
        XCTAssertEqual(ahead.state, .ahead)
        let starting = PeriodGoalPace.evaluate(.init(aggregation: .count, target: 4, days: week([0, 0]),
                                                     todayIndex: 1))
        XCTAssertEqual(starting.state, .starting)
        let done = PeriodGoalPace.evaluate(.init(aggregation: .count, target: 4, days: week([1, 1, 1, 1]),
                                                 todayIndex: 3))
        XCTAssertEqual(done.state, .achieved)
        XCTAssertEqual(done.remaining, 0)
        XCTAssertNil(done.requiredPerDay)
    }

    func testProtectedIsNeverJudged() {
        let r = PeriodGoalPace.evaluate(.init(aggregation: .count, target: 4, days: week([0, 0, 0, 0, 0, 0]),
                                              todayIndex: 5, isProtected: true))
        XCTAssertEqual(r.state, .protected)
    }

    func testRestDaysCarryNoPace() {
        // Saturday and Sunday are rest days: the pace spreads 4 over five days.
        let r = PeriodGoalPace.evaluate(.init(aggregation: .count, target: 4,
                                              days: week([1, 0, 1, 0], rest: [5, 6]), todayIndex: 3,
                                              typicalDailyUpper: 1))
        XCTAssertEqual(r.paceFraction ?? -1, 0.7, accuracy: 1e-9)   // 3.5 of 5 planned days
        XCTAssertEqual(r.state, .close)
        XCTAssertEqual(r.remainingDays, 2)
        XCTAssertEqual(r.requiredPerDay ?? -1, 1, accuracy: 1e-9)
    }

    func testGoalStartedMidWeekIsProrated() {
        // Set up on Thursday: 4 × 4/7 ≈ 2.3 → 2 runs for this first week, Monday's run not counted.
        let r = PeriodGoalPace.evaluate(.init(aggregation: .count, target: 4, days: week([1, 0, 0, 0]),
                                              todayIndex: 3, activeFromIndex: 3))
        XCTAssertTrue(r.isProrated)
        XCTAssertEqual(r.target, 2)
        XCTAssertEqual(r.current, 0)
        XCTAssertEqual(r.state, .starting)
    }

    // MARK: - Average goals

    func testAverageSleepOnTrackWithAMissingNight() {
        let r = PeriodGoalPace.evaluate(.init(aggregation: .average, target: 7.5,
                                              days: week([7.0, 8.0, nil, 7.2, nil, nil, nil]), todayIndex: 3))
        XCTAssertEqual(r.current, 7.4, accuracy: 1e-9)
        XCTAssertEqual(r.state, .onTrack)
        XCTAssertEqual(r.missingDays, 1)
        XCTAssertEqual(r.requiredPerDay ?? -1, 7.6, accuracy: 1e-9)
        XCTAssertNil(r.paceFraction)
    }

    func testAverageBehindOrCloseByCapacity() {
        let days = week([6.5, 6.8, nil, 6.6, nil, nil, nil])
        let behind = PeriodGoalPace.evaluate(.init(aggregation: .average, target: 7.5, days: days, todayIndex: 3))
        XCTAssertEqual(behind.state, .behind)
        XCTAssertEqual(behind.requiredPerDay ?? -1, (45.0 - 19.9) / 3.0, accuracy: 1e-9)
        let close = PeriodGoalPace.evaluate(.init(aggregation: .average, target: 7.5, days: days, todayIndex: 3,
                                                  typicalDailyUpper: 8.5))
        XCTAssertEqual(close.state, .close)
    }

    func testAverageWithMostlyMissingNightsSaysNoData() {
        let r = PeriodGoalPace.evaluate(.init(aggregation: .average, target: 7.5,
                                              days: week([nil, nil, 7.0, nil, nil, nil, nil]), todayIndex: 3))
        XCTAssertEqual(r.state, .noData)
    }

    // MARK: - Outcomes and series

    func testOutcomes() {
        XCTAssertEqual(PeriodGoalPace.outcome(.init(aggregation: .count, target: 4,
                                                    days: week([1, 0, 1, 0, 1, 0, 0]), todayIndex: 0)), .missed)
        XCTAssertEqual(PeriodGoalPace.outcome(.init(aggregation: .count, target: 4,
                                                    days: week([1, 1, 1, 0, 1, 0, 0]), todayIndex: 0)), .achieved)
        XCTAssertEqual(PeriodGoalPace.outcome(.init(aggregation: .sum, target: 100,
                                                    days: week([40, 0, 40, 0, 0, 0, 0]), todayIndex: 0)), .almost)
        XCTAssertEqual(PeriodGoalPace.outcome(.init(aggregation: .count, target: 4, days: week([]),
                                                    todayIndex: 0, isProtected: true)), .protected)
        XCTAssertEqual(PeriodGoalPace.outcome(.init(aggregation: .average, target: 7,
                                                    days: week([7, nil, nil, nil, nil, 8, nil]),
                                                    todayIndex: 0)), .noData)
    }

    func testStreakSkipsProtectedAndBreaksOnMissed() {
        let s = PeriodGoalPace.streak([.achieved, .almost, .protected, .missed, .achieved, .achieved, .noData,
                                       .almost])
        XCTAssertEqual(s.current, 3)
        XCTAssertEqual(s.best, 3)
        XCTAssertEqual(PeriodGoalPace.streak([]).current, 0)
    }

    func testTypicalDailyUpper() {
        XCTAssertNil(PeriodGoalPace.typicalDailyUpper([0, 30, 0, 45]))
        XCTAssertEqual(PeriodGoalPace.typicalDailyUpper([0, 30, 45, 60, 0, 40]) ?? -1, 48.75, accuracy: 1e-9)
    }

    // MARK: - Recommendations

    func testRecommendationLevelsForCounts() {
        let r = PeriodGoalRecommender.levels(history: [2, 3, 2, 3, 1, 2], aggregation: .count, step: 1,
                                             minimum: 1)
        XCTAssertEqual(r?.easy.value, 2)
        XCTAssertEqual(r?.recommended.value, 3)
        XCTAssertEqual(r?.ambitious.value, 4)
        XCTAssertEqual(r?.easy.hits, 5)
        XCTAssertEqual(r?.recommended.hits, 2)
        XCTAssertEqual(r?.ambitious.hits, 0)
        XCTAssertEqual(r?.recommended.periods, 6)
    }

    func testRecommendationLevelsForAnAverage() {
        let r = PeriodGoalRecommender.levels(history: [7.0, 7.2, 6.8], aggregation: .average, step: 0.25,
                                             minimum: 5)
        XCTAssertEqual(r?.easy.value, 7.0)
        XCTAssertEqual(r?.recommended.value, 7.25)
        XCTAssertEqual(r?.ambitious.value, 7.5)
    }

    func testNoRecommendationWithoutHistory() {
        XCTAssertNil(PeriodGoalRecommender.levels(history: [3], aggregation: .count, step: 1, minimum: 1))
    }

    // MARK: - Step plan

    func testRampPlanSpreadsStepsOverTheRunway() {
        XCTAssertEqual(PeriodRampPlan.target(start: 2, goal: 4, totalWeeks: 12, weekIndex: 0, step: 1), 2)
        XCTAssertEqual(PeriodRampPlan.target(start: 2, goal: 4, totalWeeks: 12, weekIndex: 5, step: 1), 2)
        XCTAssertEqual(PeriodRampPlan.target(start: 2, goal: 4, totalWeeks: 12, weekIndex: 6, step: 1), 3)
        XCTAssertEqual(PeriodRampPlan.target(start: 2, goal: 4, totalWeeks: 12, weekIndex: 12, step: 1), 4)
        // A short runway still holds each step for three weeks.
        XCTAssertEqual(PeriodRampPlan.target(start: 2, goal: 4, totalWeeks: 3, weekIndex: 3, step: 1), 3)
        XCTAssertEqual(PeriodRampPlan.target(start: 2, goal: 4, totalWeeks: 3, weekIndex: 6, step: 1), 4)
    }

    // MARK: - Calendar

    func testPeriodCalendar() {
        let week = PeriodCalendar.weekDays(containing: "2026-10-04", firstWeekday: 2)
        XCTAssertEqual(week.first, "2026-09-28")
        XCTAssertEqual(week.last, "2026-10-04")
        XCTAssertEqual(PeriodCalendar.weekDays(containing: "2026-10-04", firstWeekday: 1).first, "2026-10-04")
        XCTAssertEqual(PeriodCalendar.monthDays(containing: "2026-02-10").count, 28)
        XCTAssertEqual(PeriodCalendar.monthDays(containing: "2028-02-10").count, 29)
        XCTAssertEqual(PeriodCalendar.weekday("2026-10-04"), 1)
        XCTAssertEqual(PeriodCalendar.weekday("2026-10-05"), 2)
    }
}
