import XCTest
@testable import StrandAnalytics
import WhoopStore

/// P5: the history view's periods, gaps, level line and bands.
final class TrainingHistoryTests: XCTestCase {

    private func day(_ offset: Int, from base: String = "2026-01-01") -> String {
        WeeklyDigestEngine.addDays(base, offset)
    }

    // MARK: - Range and resolution

    func testResolutionFollowsTheSpan() {
        XCTAssertEqual(TrainingHistoryResolution.forWindow(days: 92), .day)
        XCTAssertEqual(TrainingHistoryResolution.forWindow(days: 93), .week)
        XCTAssertEqual(TrainingHistoryResolution.forWindow(days: 731), .week)
        XCTAssertEqual(TrainingHistoryResolution.forWindow(days: 732), .month)

        let three = TrainingHistory.range(span: .threeMonths, end: "2026-09-24", earliest: nil)
        XCTAssertEqual(three.resolution, .day)
        XCTAssertEqual(TrainingHistory.periods(three).count, 92)
        XCTAssertEqual(three.last, "2026-09-24")

        let year = TrainingHistory.range(span: .oneYear, end: "2026-09-24", earliest: nil)
        XCTAssertEqual(year.resolution, .week)
        XCTAssertEqual(WeeklyDigestEngine.mondayOfWeek(containing: year.first), year.first, "weeks start on Monday")

        let five = TrainingHistory.range(span: .fiveYears, end: "2026-09-24", earliest: nil)
        XCTAssertEqual(five.resolution, .month)
        XCTAssertTrue(five.first.hasSuffix("-01"))
    }

    func testAllStartsAtTheFirstRecordedDay() {
        let short = TrainingHistory.range(span: .all, end: "2026-09-24", earliest: "2026-08-01")
        XCTAssertEqual(short.first, "2026-08-01")
        XCTAssertEqual(short.resolution, .day)

        let long = TrainingHistory.range(span: .all, end: "2026-09-24", earliest: "2016-03-15")
        XCTAssertEqual(long.first, "2016-03-01")
        XCTAssertEqual(long.resolution, .month)
        XCTAssertEqual(TrainingHistory.periods(long).count, 127)

        let empty = TrainingHistory.range(span: .all, end: "2026-09-24", earliest: nil)
        XCTAssertEqual(TrainingHistory.periods(empty).count, 1)
    }

    func testPeriodsTileTheRangeWithoutGapsOrOverlap() {
        for span in TrainingHistorySpan.allCases {
            let range = TrainingHistory.range(span: span, end: "2026-09-24", earliest: "2019-02-27")
            let periods = TrainingHistory.periods(range)
            XCTAssertEqual(periods.first?.start, range.first, "\(span)")
            XCTAssertEqual(periods.last?.end, range.last, "\(span)")
            for (a, b) in zip(periods, periods.dropFirst()) {
                XCTAssertEqual(WeeklyDigestEngine.addDays(a.end, 1), b.start, "\(span)")
            }
        }
        let months = TrainingHistory.periods(TrainingHistoryRange(first: "2024-01-01", last: "2024-03-10",
                                                                 resolution: .month))
        XCTAssertEqual(months.map(\.days), [31, 29, 10], "a leap February, and a current month cut short")
        let weeks = TrainingHistory.periods(TrainingHistoryRange(first: "2026-09-07", last: "2026-09-24",
                                                                resolution: .week))
        XCTAssertEqual(weeks.map(\.days), [7, 7, 4])
    }

    // MARK: - A lane

    /// Rest is a known zero, an unpriced day is a gap, and days outside the recorded history are neither.
    func testRestGapsAndUnrecordedDaysStayApart() {
        let periods = [TrainingHistoryPeriod(start: day(0), end: day(6)),
                       TrainingHistoryPeriod(start: day(7), end: day(13))]
        let loads = [day(2): 50.0, day(8): 40, day(9): 30]
        let lane = TrainingHistory.lane(dailyByDay: loads, unknownDays: [day(10)], historyStart: day(2),
                                        through: day(11), periods: periods)
        XCTAssertEqual(lane[0].total, 50)
        XCTAssertEqual(lane[0].knownDays, 5, "days 2–6: one session, four rest days")
        XCTAssertEqual(lane[0].unrecordedDays, 2, "days 0–1 are before the history began")
        XCTAssertEqual(lane[1].total, 70)
        XCTAssertEqual(lane[1].knownDays, 4)
        XCTAssertEqual(lane[1].unknownDays, 1)
        XCTAssertEqual(lane[1].unrecordedDays, 2, "days 12–13 are after the reading day")
        XCTAssertEqual(lane[1].coverage ?? 0, 0.8, accuracy: 1e-9)
    }

    /// P4: an estimate fills a gap only in its own column. The measured total, the level and the band
    /// never read it.
    func testEstimatesStayApartFromTheMeasuredTotal() {
        let periods = [TrainingHistoryPeriod(start: day(0), end: day(6))]
        let lane = TrainingHistory.lane(dailyByDay: [day(1): 40], unknownDays: [day(3), day(5)],
                                        estimatedByDay: [day(3): 25], historyStart: day(0), through: day(6),
                                        periods: periods)
        XCTAssertEqual(lane[0].total, 40)
        XCTAssertEqual(lane[0].estimatedTotal, 25)
        XCTAssertEqual(lane[0].estimatedDays, 1)
        XCTAssertEqual(lane[0].unknownDays, 1, "the day without an estimate is still a gap")
        XCTAssertEqual(lane[0].knownDays, 5)
        XCTAssertEqual(lane[0].coverage ?? 0, 5.0 / 7.0, accuracy: 1e-9)
        let without = TrainingHistory.lane(dailyByDay: [day(1): 40], unknownDays: [day(3), day(5)],
                                           historyStart: day(0), through: day(6), periods: periods)
        XCTAssertEqual(lane[0].level, without[0].level, "the level reads measured load only")
        XCTAssertNil(without[0].estimatedTotal)
    }

    func testAPeriodWithoutAKnownDayHasNoTotal() {
        let periods = [TrainingHistoryPeriod(start: day(0), end: day(1))]
        let gap = TrainingHistory.lane(dailyByDay: [:], unknownDays: [day(0), day(1)], historyStart: day(0),
                                       through: day(5), periods: periods)
        XCTAssertNil(gap[0].total)
        XCTAssertEqual(gap[0].coverage, 0)
        let before = TrainingHistory.lane(dailyByDay: [:], historyStart: day(10), through: day(20), periods: periods)
        XCTAssertNil(before[0].total)
        XCTAssertNil(before[0].coverage)
        XCTAssertNil(before[0].band)
    }

    /// The level is the 42-day mean known daily load scaled to the period's recorded days — so a steady
    /// wearer's bars sit on it, whatever the resolution.
    func testLevelIsTheUsualForAPeriodThatLong() {
        var loads: [String: Double] = [:]
        for index in 0..<120 { loads[day(index)] = 10 }
        let weeks = TrainingHistory.periods(TrainingHistoryRange(first: "2026-03-02", last: day(119),
                                                                resolution: .week))
        let lane = TrainingHistory.lane(dailyByDay: loads, historyStart: day(0), through: day(119), periods: weeks)
        for entry in lane {
            XCTAssertEqual(entry.level ?? -1, entry.total ?? -2, accuracy: 1e-9, entry.period.start)
        }
    }

    func testLevelNeedsHalfItsDaysKnown() {
        var unknown = Set<String>()
        for index in 0..<42 where index % 2 == 0 { unknown.insert(day(index)) }
        let periods = [TrainingHistoryPeriod(start: day(35), end: day(41))]
        let halfKnown = TrainingHistory.lane(dailyByDay: [:], unknownDays: unknown, historyStart: day(0),
                                             through: day(41), periods: periods)
        XCTAssertNotNil(halfKnown[0].level, "21 of 42 known is enough")
        unknown.insert(day(1))
        let lessThanHalf = TrainingHistory.lane(dailyByDay: [:], unknownDays: unknown, historyStart: day(0),
                                                through: day(41), periods: periods)
        XCTAssertNil(lessThanHalf[0].level)
        let young = TrainingHistory.lane(dailyByDay: [:], historyStart: day(30), through: day(41), periods: periods)
        XCTAssertNil(young[0].level, "twelve days of history is not a usual")
    }

    /// A period's band is what `LaneEngine` read on its last recorded day — the band the Training Load
    /// screen showed that day, not a second classification.
    func testBandIsTheLaneEngineReadingAtThePeriodsEnd() {
        var loads: [String: Double] = [:]
        var sessions: [String: Int] = [:]
        for index in 0..<150 where index % 2 == 0 {
            loads[day(index)] = index > 130 ? 30 : 10
            sessions[day(index)] = 1
        }
        let activity = LaneActivity(sessionsByDay: sessions, minutesByDay: sessions.mapValues { _ in 60 })
        let through = day(145)
        let range = TrainingHistoryRange(first: WeeklyDigestEngine.mondayOfWeek(containing: day(60))!,
                                         last: day(149), resolution: .week)
        let periods = TrainingHistory.periods(range)
        let lane = TrainingHistory.lane(dailyByDay: loads, historyStart: day(0), through: through,
                                        periods: periods, bandLane: (.strength, activity))
        for entry in lane {
            let readingDay = min(entry.period.end, through)
            let expected = LaneEngine.reading(dailyByDay: loads, activity: activity, lane: .strength,
                                              through: readingDay).band
            XCTAssertEqual(entry.band, expected, entry.period.start)
        }
        XCTAssertEqual(lane.last?.band, .muchHigher, "the tripled last weeks read well above usual")
        XCTAssertTrue(lane.contains { $0.band == .usual })
    }

    func testSessionQuotaSumsOverThePeriod() {
        let periods = [TrainingHistoryPeriod(start: day(0), end: day(6))]
        let lane = TrainingHistory.lane(dailyByDay: [day(1): 300], unknownDays: [day(3)], historyStart: day(0),
                                        through: day(6), periods: periods,
                                        measuredByDay: [day(1): 1], possibleByDay: [day(1): 1, day(3): 2])
        XCTAssertEqual(lane[0].measured, 1)
        XCTAssertEqual(lane[0].possible, 3)
        let noQuota = TrainingHistory.lane(dailyByDay: [:], historyStart: day(0), through: day(6), periods: periods)
        XCTAssertNil(noQuota[0].measured)
    }

    // MARK: - Values beside the load

    func testValuesSummarisePerPeriod() {
        let periods = [TrainingHistoryPeriod(start: day(0), end: day(6)),
                       TrainingHistoryPeriod(start: day(7), end: day(13)),
                       TrainingHistoryPeriod(start: day(14), end: day(20))]
        let points = [(day: day(1), value: 100.0), (day: day(5), value: 110), (day: day(15), value: 105),
                      (day: day(30), value: 999)]
        XCTAssertEqual(TrainingHistory.maxPerPeriod(points, periods: periods).map(\.value), [110, nil, 105])
        XCTAssertEqual(TrainingHistory.meanPerPeriod(points, periods: periods).map(\.value), [105, nil, 105])
    }

    // MARK: - Lifts

    private func workout(_ id: String, day: String, templates: [String]) -> HevyWorkout {
        let ts = Int(ISO8601DateFormatter().date(from: day + "T12:00:00Z")!.timeIntervalSince1970)
        let exercises = templates.enumerated().map { index, template in
            HevyExercise(index: index, title: template, templateId: template, supersetId: nil, notes: nil,
                         sets: [HevySet(index: 0, type: .normal, weightKg: 100, reps: 5, distanceM: nil,
                                        durationS: nil, rpe: nil, customMetric: nil)])
        }
        return HevyWorkout(id: id, title: "W", routineId: nil, notes: nil, startTs: ts, endTs: ts + 3_600,
                           updatedAtTs: ts, createdAtTs: ts, exercises: exercises)
    }

    func testMostTrainedLiftsAndTheirLine() {
        let workouts = [
            workout("a", day: day(0), templates: ["squat", "bench", "row"]),
            workout("b", day: day(2), templates: ["squat", "bench"]),
            workout("c", day: day(4), templates: ["squat", "deadlift", "curl"]),
            workout("d", day: day(40), templates: ["curl", "curl2", "curl3", "curl4"])
        ]
        let top = TrainingHistory.mostTrainedTemplates(workouts: workouts, templates: [:], from: day(0),
                                                       through: day(10))
        XCTAssertEqual(top, ["squat", "bench", "curl"], "most sessions first, ties by id")

        let periods = [TrainingHistoryPeriod(start: day(0), end: day(6)),
                       TrainingHistoryPeriod(start: day(7), end: day(13))]
        let line = TrainingHistory.liftSeries(templateId: "squat", workouts: workouts, templates: [:],
                                              periods: periods)
        XCTAssertEqual(line[0].value ?? 0, 100 * (1 + 5.0 / 30), accuracy: 1e-9)
        XCTAssertNil(line[1].value)
    }
}
