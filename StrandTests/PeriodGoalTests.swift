import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Weekly and monthly goals: persistence, the backup bundle, the tracker's day values, history and the
/// maintenance suggestions.
@MainActor
final class PeriodGoalTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 2
        return c
    }

    private func date(_ day: String, hour: Int = 12) -> Date {
        let p = day.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour))!
    }

    private func suite(_ name: String = #function) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "PeriodGoalTests.\(name)")!
        defaults.removePersistentDomain(forName: "PeriodGoalTests.\(name)")
        return defaults
    }

    private func workout(_ day: String, _ sport: String, minutes: Double = 40, km: Double? = nil) -> WorkoutRow {
        let start = Int(date(day, hour: 7).timeIntervalSince1970)
        return WorkoutRow(startTs: start, endTs: start + Int(minutes * 60), sport: sport, source: "manual",
                          durationS: minutes * 60, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                          distanceM: km.map { $0 * 1000 }, zonesJSON: nil, notes: nil, steps: nil)
    }

    private func day(_ key: String, sleepMin: Double? = nil, steps: Int? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                    exerciseCount: nil, steps: steps)
    }

    private func snapshot(_ goal: PeriodGoal, inputs: PeriodGoalInputs, now: String,
                          corrections: [GoalCountingCorrections.Correction] = []) -> PeriodGoalSnapshot {
        PeriodGoalTracker.snapshots(goals: [goal], inputs: inputs, parents: [], frozen: [],
                                    corrections: corrections, now: date(now), calendar: calendar)[0]
    }

    // MARK: - Model and store

    func testPeriodGoalDecodesWithDefaults() throws {
        let json = #"{"metric":"stepDays","period":"month","target":20}"#
        let goal = try JSONDecoder().decode(PeriodGoal.self, from: Data(json.utf8))
        XCTAssertEqual(goal.metric, .stepDays)
        XCTAssertEqual(goal.period, .month)
        XCTAssertEqual(goal.status, .active)
        XCTAssertEqual(goal.sportFilter, [])
        XCTAssertNil(goal.oneOffPeriodStart)
        XCTAssertTrue(goal.habitWantsYes)
    }

    func testTargetChangeKeepsEarlierPeriods() {
        let store = PeriodGoalStore(defaults: suite())
        store.commit(PeriodGoal(metric: .workouts, period: .week, target: 3, createdAt: date("2026-09-01")),
                     today: "2026-09-01")
        let id = store.goals[0].id
        store.setTarget(id, 4, today: "2026-09-15")
        let goal = store.goals[0]
        XCTAssertEqual(goal.target, 4)
        XCTAssertEqual(goal.target(forPeriodStarting: "2026-09-08"), 3)
        XCTAssertEqual(goal.target(forPeriodStarting: "2026-09-15"), 4)
        XCTAssertEqual(goal.target(forPeriodStarting: "2026-08-01"), 3)
    }

    func testDuplicatesNeedADifferentPeriodOrSport() {
        let store = PeriodGoalStore(defaults: suite())
        store.commit(PeriodGoal(metric: .workouts, period: .week, target: 3), today: "2026-10-01")
        XCTAssertNotNil(store.canAdd(PeriodGoal(metric: .workouts, period: .week, target: 4)))
        XCTAssertNil(store.canAdd(PeriodGoal(metric: .workouts, period: .month, target: 12)))
        XCTAssertNil(store.canAdd(PeriodGoal(metric: .workouts, period: .week, target: 2, sportFilter: ["Running"])))
    }

    func testStoreSurvivesAReload() {
        let defaults = suite()
        let store = PeriodGoalStore(defaults: defaults)
        store.commit(PeriodGoal(metric: .sleepNights, period: .week, target: 5, threshold: 7), today: "2026-10-01")
        store.freeze([PeriodGoalResult(goalId: store.goals[0].id, periodStart: "2026-09-21", target: 5, value: 5,
                                       outcome: .achieved, frozenAt: Date())])
        let reloaded = PeriodGoalStore(defaults: defaults)
        XCTAssertEqual(reloaded.goals, store.goals)
        XCTAssertEqual(reloaded.results.count, 1)
        // Freezing the same period again adds nothing: a frozen result is never rewritten.
        XCTAssertEqual(reloaded.freeze(reloaded.results), 0)
    }

    func testChainPausesAndUnlinks() {
        let store = PeriodGoalStore(defaults: suite())
        let parent = UUID()
        store.commit(PeriodGoal(metric: .workouts, period: .week, target: 3, parentGoalId: parent), today: "2026-10-01")
        store.parentPaused(parent, reason: .illness)
        XCTAssertEqual(store.goals[0].status, .paused)
        store.parentResumed(parent)
        XCTAssertEqual(store.goals[0].status, .active)
        store.parentRemoved(parent)
        XCTAssertNil(store.goals[0].parentGoalId)
    }

    // MARK: - Backup

    func testBackupBundleRoundTripsGoalKeysOnly() throws {
        let source = suite("source")
        source.set(Data("goals".utf8), forKey: "ai.goals")
        source.set(Data("period".utf8), forKey: PeriodGoalStore.storageKey)
        source.set([1, 7], forKey: "training.restWeekdays")
        source.set(8, forKey: GoalPrefs.periodLimitKey)
        source.set("unrelated", forKey: "profile.sex")
        let bundle = try XCTUnwrap(GoalBackupBundle.encode(from: source))

        let target = suite("target")
        XCTAssertEqual(GoalBackupBundle.apply(bundle, to: target), 4)
        XCTAssertEqual(target.data(forKey: "ai.goals"), Data("goals".utf8))
        XCTAssertEqual(target.data(forKey: PeriodGoalStore.storageKey), Data("period".utf8))
        XCTAssertEqual(target.array(forKey: "training.restWeekdays") as? [Int], [1, 7])
        XCTAssertEqual(target.integer(forKey: GoalPrefs.periodLimitKey), 8)
        XCTAssertNil(target.string(forKey: "profile.sex"))

        // A bundle naming a non-goal key cannot write it.
        let plist = try PropertyListSerialization.data(fromPropertyList: ["x"], format: .binary, options: 0)
        let hostile = #"{"v":1,"entries":{"profile.sex":"\#(plist.base64EncodedString())"}}"#
        XCTAssertEqual(GoalBackupBundle.apply(hostile, to: target), 0)
        XCTAssertEqual(GoalBackupBundle.apply("not json", to: target), 0)
    }

    // MARK: - Tracker

    func testWorkoutGoalCountsBySportAndHonoursCorrections() {
        // Week of Mon 2026-10-05; today Thursday.
        var inputs = PeriodGoalInputs()
        inputs.workouts = [workout("2026-10-05", "Running"), workout("2026-10-06", "Walking"),
                           workout("2026-10-07", "Running")]
        let goal = PeriodGoal(metric: .workouts, period: .week, target: 3, sportFilter: ["Running"],
                              createdAt: date("2026-09-01"))
        let plain = snapshot(goal, inputs: inputs, now: "2026-10-08")
        XCTAssertEqual(plain.periodStart, "2026-10-05")
        XCTAssertEqual(plain.result.current, 2)
        XCTAssertEqual(plain.notCounted.map(\.title), ["Walking"])

        let walkKey = PlanWorkoutReference(workout("2026-10-06", "Walking")).workoutKey
        let corrected = snapshot(goal, inputs: inputs, now: "2026-10-08",
                                 corrections: [.init(goalId: goal.id, workoutKey: walkKey, counts: true)])
        XCTAssertEqual(corrected.result.current, 3)
        XCTAssertEqual(corrected.state, .achieved)
        XCTAssertTrue(corrected.counted.contains { $0.id == walkKey && $0.isManual })
    }

    func testDistanceGoalSumsKilometres() {
        var inputs = PeriodGoalInputs()
        inputs.workouts = [workout("2026-10-01", "Running", km: 8.5), workout("2026-10-03", "Running", km: 10),
                           workout("2026-10-03", "Cycling", km: 30)]
        let goal = PeriodGoal(metric: .distance, period: .month, target: 60, sportFilter: ["Running"],
                              createdAt: date("2026-09-01"))
        let s = snapshot(goal, inputs: inputs, now: "2026-10-04")
        XCTAssertEqual(s.periodDays.count, 31)
        XCTAssertEqual(s.result.current, 18.5, accuracy: 1e-9)
    }

    func testSleepNightsAreHitDaysAndMissingNightsAreNotZero() {
        var inputs = PeriodGoalInputs()
        inputs.days = [day("2026-10-05", sleepMin: 480), day("2026-10-06", sleepMin: 380),
                       day("2026-10-08", sleepMin: 450)]
        let goal = PeriodGoal(metric: .sleepNights, period: .week, target: 5, threshold: 7,
                              createdAt: date("2026-09-01"))
        let s = snapshot(goal, inputs: inputs, now: "2026-10-08")
        XCTAssertEqual(s.result.current, 2)
        XCTAssertEqual(s.dayValues[2], nil, "a night without data is missing, not a miss")
        XCTAssertEqual(s.dayValues[1], 0)
    }

    func testHistorySeriesAndStepUpSuggestion() {
        // Three earlier weeks with four runs each against a target of four.
        var rows: [WorkoutRow] = []
        for weekStart in ["2026-09-14", "2026-09-21", "2026-09-28"] {
            for offset in 0..<4 { rows.append(workout(WeeklyDigestEngine.addDays(weekStart, offset), "Running")) }
        }
        var inputs = PeriodGoalInputs()
        inputs.workouts = rows
        let goal = PeriodGoal(metric: .workouts, period: .week, target: 4, targetHistory: [.init(fromDay: "2026-09-14", target: 4)],
                              createdAt: date("2026-09-14"))
        let s = snapshot(goal, inputs: inputs, now: "2026-10-06")
        XCTAssertEqual(s.history.map(\.outcome), [.achieved, .achieved, .achieved])
        XCTAssertEqual(s.currentStreak, 3)
        XCTAssertEqual(GoalMaintenance.adjustment(for: s), 5)
    }

    func testGoalStartedMidWeekIsProratedAndIgnoresEarlierDays() {
        var inputs = PeriodGoalInputs()
        inputs.workouts = [workout("2026-10-05", "Running")]
        let goal = PeriodGoal(metric: .workouts, period: .week, target: 4, createdAt: date("2026-10-08"))
        let s = snapshot(goal, inputs: inputs, now: "2026-10-08")
        XCTAssertTrue(s.result.isProrated)
        XCTAssertEqual(s.result.target, 2)
        XCTAssertEqual(s.result.current, 0)
        XCTAssertTrue(s.history.isEmpty)
    }

    func testSuggestedDaysSpreadToTheEndOfTheWeek() {
        var inputs = PeriodGoalInputs()
        inputs.workouts = [workout("2026-10-05", "Running"), workout("2026-10-07", "Running")]
        let goal = PeriodGoal(metric: .workouts, period: .week, target: 4, createdAt: date("2026-09-01"))
        let s = snapshot(goal, inputs: inputs, now: "2026-10-08")
        // Thursday, nothing yet today: Thu Fri Sat Sun are open, two are needed.
        XCTAssertEqual(s.suggestedDays, ["2026-10-09", "2026-10-11"])
    }

    func testRecommendationReadsCompletedWeeks() {
        var rows: [WorkoutRow] = []
        let counts = [2, 3, 2, 3, 2, 3, 2, 3]
        var weekStart = "2026-08-10"
        for count in counts {
            for offset in 0..<count { rows.append(workout(WeeklyDigestEngine.addDays(weekStart, offset), "Running")) }
            weekStart = WeeklyDigestEngine.addDays(weekStart, 7)
        }
        var inputs = PeriodGoalInputs()
        inputs.workouts = rows
        let draft = PeriodGoal(metric: .workouts, period: .week, target: 3)
        let rec = PeriodGoalTracker.recommendation(for: draft, inputs: inputs, now: date("2026-10-07"),
                                                   calendar: calendar)
        XCTAssertEqual(rec?.easy.periods, 8)
        XCTAssertEqual(rec?.easy.value, 3)          // median of 2s and 3s is 2.5, rounds to 3
        XCTAssertEqual(rec?.recommended.value, 4)
    }
}
