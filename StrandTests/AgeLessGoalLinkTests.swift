import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// AgeLess stage 2: a lever turns into the goal on the same number, pre-filled so it is never reached on the
/// day it is set, and a goal's AgeLess years come from the levers' own rule.
@MainActor
final class AgeLessGoalLinkTests: XCTestCase {

    private let week = HealthspanEngine.Inputs(age: 35, sex: .male, sleepHours: 6.4, sleepConsistencyPct: 60,
                                               dailySteps: 5200, zone13MinPerWeek: 60, zone45MinPerWeek: 0,
                                               strengthMinPerWeek: 0, vo2max: 40, restingHR: 66, leanMassPct: 74)

    func testEveryLeverMapsToTheGoalOnTheSameNumber() throws {
        XCTAssertEqual(AgeLessGoalLink.template(for: .sleepDuration), .sleepAverage)
        XCTAssertEqual(AgeLessGoalLink.template(for: .sleepConsistency), .sleepConsistency)
        XCTAssertEqual(AgeLessGoalLink.template(for: .dailySteps), .stepsAverage)
        XCTAssertEqual(AgeLessGoalLink.template(for: .zone13), .moderateWeekly)
        XCTAssertEqual(AgeLessGoalLink.template(for: .zone45), .vigorousWeekly)
        XCTAssertEqual(AgeLessGoalLink.template(for: .strength), .strengthMinutesWeekly)
        XCTAssertEqual(AgeLessGoalLink.template(for: .restingHR), .sleepHeartRate)
        XCTAssertEqual(AgeLessGoalLink.template(for: .vo2max), .vo2max)
        XCTAssertEqual(AgeLessGoalLink.template(for: .leanMass), .bodyFat)
        for c in HealthspanEngine.Component.allCases {
            let t = try XCTUnwrap(AgeLessGoalLink.template(for: c), "\(c)")
            // "Goal running" recognises the lever's own template, and the goal prices back onto the measure.
            XCTAssertTrue(AgeLessGoalLink.templates(for: c).contains(t), "\(c)")
            XCTAssertEqual(AgeLessGoalLink.agelessTarget(template: t, target: 50)?.component, c, "\(c)")
            XCTAssertNotNil(GoalCatalog.template(t), "\(c)")
        }
        // The weekly rhythms read the AgeLess weekly metrics.
        XCTAssertEqual(GoalTemplateID.moderateWeekly.weeklyMetric, .moderateMinutes)
        XCTAssertEqual(GoalTemplateID.vigorousWeekly.weeklyMetric, .vigorousMinutes)
        XCTAssertEqual(GoalTemplateID.strengthMinutesWeekly.weeklyMetric, .strengthMinutes)
    }

    /// The further of the lever's value and the goal's own current value plus the step, rounded ambitiously.
    func testPrefillIsNeverReachedOnTheDayItIsSet() {
        let steps = AgeLessGoalPrefill(template: .stepsAverage, leverValue: 6200, stepSize: 1000, higherIsBetter: true)
        XCTAssertEqual(AgeLessGoalLink.target(steps, goalCurrent: 5000, step: 500, range: 1000...40000), 6500)
        // The last four weeks already beat the lever: one step past them.
        XCTAssertEqual(AgeLessGoalLink.target(steps, goalCurrent: 7300, step: 500, range: 1000...40000), 8500)
        XCTAssertEqual(AgeLessGoalLink.target(steps, goalCurrent: nil, step: 500, range: 1000...40000), 6500)
        let hr = AgeLessGoalPrefill(template: .sleepHeartRate, leverValue: 63, stepSize: 3, higherIsBetter: false)
        XCTAssertEqual(AgeLessGoalLink.target(hr, goalCurrent: 64.4, step: 1, range: 30...110), 61)
        XCTAssertEqual(AgeLessGoalLink.target(hr, goalCurrent: 70, step: 1, range: 30...110), 63)
    }

    /// A lean-mass lever becomes a body-fat goal: two points more lean mass is two points less body fat.
    func testLeanMassLeverBecomesBodyFat() throws {
        let lever = try XCTUnwrap(HealthspanEngine.levers(week, limit: 9).first { $0.component == .leanMass })
        XCTAssertEqual(lever.newValue, 76)
        let p = try XCTUnwrap(AgeLessGoalLink.prefill(for: lever))
        XCTAssertEqual(p.template, .bodyFat)
        XCTAssertEqual(p.leverValue, 24)
        XCTAssertEqual(p.stepSize, 2)
        XCTAssertFalse(p.higherIsBetter)
        let mapped = try XCTUnwrap(AgeLessGoalLink.agelessTarget(template: .bodyFat, target: 24))
        XCTAssertEqual(mapped.component, .leanMass)
        XCTAssertEqual(mapped.value, 76)
        XCTAssertNil(AgeLessGoalLink.agelessTarget(template: .leanMass, target: 60), "lean mass goals are in kg")
    }

    /// A goal on a lever's number names the lever's years; one AgeLess already meets names none.
    func testGoalYearsFollowTheLeversRule() throws {
        let lever = try XCTUnwrap(HealthspanEngine.levers(week, limit: 9).first { $0.component == .vo2max })
        let goal = CoachGoal(kind: .fitness, title: "VO2max", baseline: 40, target: lever.newValue,
                             templateId: GoalTemplateID.vo2max.rawValue, measure: .init(metric: .vo2max))
        XCTAssertEqual(try XCTUnwrap(AgeLessGoalLink.years(goal: goal, week: week)), lever.years, accuracy: 1e-12)
        var met = goal
        met.target = 38
        XCTAssertNil(AgeLessGoalLink.years(goal: met, week: week))
        let lean = CoachGoal(kind: .body, title: "Lean", baseline: 60, target: 62,
                             templateId: GoalTemplateID.leanMass.rawValue, measure: .init(metric: .leanMass))
        XCTAssertNil(AgeLessGoalLink.years(goal: lean, week: week))
    }

    /// A weekly rhythm's target is its weekly amount, priced as AgeLess's weekly rate.
    func testWeeklyRhythmGoalsArePricedPerWeek() throws {
        let lever = try XCTUnwrap(HealthspanEngine.levers(week, limit: 9).first { $0.component == .zone13 })
        let goal = CoachGoal(kind: .fitness, title: "Moderate", target: lever.newValue,
                             templateId: GoalTemplateID.moderateWeekly.rawValue, measure: .init(metric: .weeklyAdherence))
        XCTAssertEqual(try XCTUnwrap(AgeLessGoalLink.years(goal: goal, week: week)), lever.years, accuracy: 1e-12)
        // The three rhythms share a metric; only the template tells them apart.
        let vigorous = CoachGoal(kind: .fitness, title: "Vigorous", target: 20,
                                 templateId: GoalTemplateID.vigorousWeekly.rawValue, measure: .init(metric: .weeklyAdherence))
        XCTAssertNil(AgeLessGoalLink.runningGoal(for: .zone13, in: [vigorous]))
        XCTAssertEqual(AgeLessGoalLink.runningGoal(for: .zone45, in: [vigorous])?.id, vigorous.id)
    }

    /// "Goal running" counts open goals on the same number only.
    func testRunningGoalMatchesTheSameNumber() {
        let stepDays = CoachGoal(kind: .activity, title: "Step days", templateId: GoalTemplateID.stepDays.rawValue,
                                 measure: .init(metric: .weeklyAdherence))
        let average = CoachGoal(kind: .activity, title: "Steps", baseline: 5000, target: 6500,
                                templateId: GoalTemplateID.stepsAverage.rawValue, measure: .init(metric: .stepsAverage))
        var closed = average
        closed.status = .achieved
        XCTAssertNil(AgeLessGoalLink.runningGoal(for: .dailySteps, in: [stepDays, closed]))
        XCTAssertEqual(AgeLessGoalLink.runningGoal(for: .dailySteps, in: [stepDays, average])?.id, average.id)
        let fat = CoachGoal(kind: .body, title: "Fat", baseline: 26, target: 24,
                            templateId: GoalTemplateID.bodyFat.rawValue, measure: .init(metric: .bodyFat))
        XCTAssertEqual(AgeLessGoalLink.runningGoal(for: .leanMass, in: [fat])?.id, fat.id)
    }

    // MARK: - VO₂max goals re-read their start once (AI-24)

    private func store() -> (CoachGoalStore, UserDefaults) {
        let d = UserDefaults(suiteName: "ageless-goal-\(UUID().uuidString)")!
        return (CoachGoalStore(defaults: d), d)
    }

    private func day(_ s: String) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        let parts = s.split(separator: "-").compactMap { Int($0) }
        return c.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    func testVO2maxGoalsSetBeforeTheRuleReReadTheirStartOnce() throws {
        let (store, defaults) = store()
        let old = CoachGoal(kind: .fitness, title: "VO2max", baseline: 46, target: 50, createdAt: day("2026-09-01"),
                            templateId: GoalTemplateID.vo2max.rawValue, measure: .init(metric: .vo2max))
        let waiting = CoachGoal(kind: .fitness, title: "VO2max later", baseline: 46, target: 52,
                                createdAt: day("2026-10-12"),
                                templateId: GoalTemplateID.vo2max.rawValue, measure: .init(metric: .vo2max))
        store.goals = [old, waiting]
        let readings = [GoalMilestones.Sample(date: day("2026-08-20"), value: 39),
                        GoalMilestones.Sample(date: day("2026-09-03"), value: 41.2),
                        GoalMilestones.Sample(date: day("2026-09-10"), value: 42)]
        store.rebaselineVO2maxGoals(readings: readings)
        XCTAssertEqual(store.goal(id: old.id)?.baseline, 41, "first reading on or after the start, to the half")
        XCTAssertEqual(store.goal(id: old.id)?.history.last?.what, "Start re-read from the VO₂max AgeLess uses")
        XCTAssertEqual(store.goal(id: waiting.id)?.baseline, 46, "no reading since it was set yet")
        XCTAssertEqual(defaults.stringArray(forKey: CoachGoalStore.vo2maxRebaselinePendingKey), [waiting.id.uuidString])

        // A goal set after the first run is never listed; the waiting one is re-read once its reading arrives.
        let fresh = CoachGoal(kind: .fitness, title: "VO2max new", baseline: 42, target: 45,
                              createdAt: day("2026-10-13"),
                              templateId: GoalTemplateID.vo2max.rawValue, measure: .init(metric: .vo2max))
        store.goals.append(fresh)
        store.rebaselineVO2maxGoals(readings: readings + [GoalMilestones.Sample(date: day("2026-10-13"), value: 43)])
        XCTAssertEqual(store.goal(id: waiting.id)?.baseline, 43)
        XCTAssertEqual(store.goal(id: fresh.id)?.baseline, 42)
        XCTAssertEqual(store.goal(id: old.id)?.baseline, 41, "re-read once only")
        XCTAssertEqual(defaults.stringArray(forKey: CoachGoalStore.vo2maxRebaselinePendingKey), [])
    }

    /// A start on or past the target would read as reached before it began, so it stays.
    func testAStartPastTheTargetIsLeftAlone() {
        let (store, _) = store()
        let goal = CoachGoal(kind: .fitness, title: "VO2max", baseline: 44, target: 48, createdAt: day("2026-09-01"),
                             templateId: GoalTemplateID.vo2max.rawValue, measure: .init(metric: .vo2max))
        store.goals = [goal]
        store.rebaselineVO2maxGoals(readings: [GoalMilestones.Sample(date: day("2026-09-02"), value: 49)])
        XCTAssertEqual(store.goal(id: goal.id)?.baseline, 44)
    }

    // MARK: - The two new measures

    func testStepsAverageReadsDailySteps() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        let days = (0..<40).map { i -> DailyMetric in
            let key = PeriodGoalTracker.dayKey(now.addingTimeInterval(-Double(i) * 86_400), calendar: calendar)
            return DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                               disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                               exerciseCount: nil, steps: 6000 + i * 10)
        }
        let goal = CoachGoal(kind: .activity, title: "Steps", baseline: 5000, target: 7000,
                             templateId: GoalTemplateID.stepsAverage.rawValue, measure: .init(metric: .stepsAverage))
        let reading = LongTermGoalReader.reading(goal: goal, course: nil, inputs: .init(days: days),
                                                 periodSnapshots: [], now: now, calendar: calendar)
        guard case .average(let data)? = reading else { return XCTFail("expected an average reading") }
        XCTAssertEqual(data.metric, .stepsAverage)
        XCTAssertEqual(data.days.compactMap { $0 }.count, 28)
    }

    func testSleepHeartRateIsALevelLikeRestingHeartRate() {
        let rule = LongTermGoalReader.levelRule(.sleepHeartRate)
        let resting = LongTermGoalReader.levelRule(.restingHr)
        XCTAssertEqual(rule.windowDays, resting.windowDays)
        XCTAssertEqual(rule.minValues, resting.minValues)
        XCTAssertEqual(GoalTemplateID.sleepHeartRate.metric.baseShape, .target)
        XCTAssertEqual(GoalTemplateID.stepsAverage.metric.baseShape, .average)
        XCTAssertNotNil(GoalCatalog.template(.sleepHeartRate))
        XCTAssertNotNil(GoalCatalog.template(.stepsAverage))
    }

    // MARK: - Stage 3: the weekly rhythms and sleep consistency

    private func workout(_ sport: String, minutes: Double) -> WorkoutRow {
        WorkoutRow(startTs: 1_791_374_400, endTs: 1_791_374_400 + Int(minutes * 60), sport: sport, source: "apple_health",
                   durationS: minutes * 60, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                   zonesJSON: nil, notes: nil, steps: nil)
    }

    /// Strength minutes count what AgeLess counts as strength, yoga and HIIT included, and nothing else.
    func testStrengthMinutesCountWhatAgeLessCounts() {
        let goal = PeriodGoal(metric: .strengthMinutes, period: .week, target: 40)
        XCTAssertTrue(PeriodGoalTracker.workoutMatches(goal, workout("Yoga", minutes: 30)))
        XCTAssertTrue(PeriodGoalTracker.workoutMatches(goal, workout("HIIT", minutes: 20)))
        XCTAssertFalse(PeriodGoalTracker.workoutMatches(goal, workout("Running", minutes: 30)))
        XCTAssertEqual(PeriodGoalTracker.workoutAmount(.strengthMinutes, workout("Yoga", minutes: 30)), 30)
        XCTAssertEqual(PeriodMetric.strengthMinutes.aggregation, .sum)
        XCTAssertTrue(PeriodMetric.strengthMinutes.isWorkoutBased)
    }

    /// Moderate and vigorous minutes need AgeLess: without its banked minutes they are unavailable, and an open
    /// goal rests instead of missing its weeks.
    func testActivityMinutesNeedAgeLess() {
        var inputs = PeriodGoalInputs()
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        XCTAssertEqual(PeriodGoalTracker.availability(.moderateMinutes, inputs: inputs, now: now, calendar: .current),
                       .unavailable("Needs AgeLess"))
        inputs.agelessModerateByDay = ["2026-10-06": 30]
        inputs.agelessVigorousByDay = [:]
        XCTAssertEqual(PeriodGoalTracker.availability(.vigorousMinutes, inputs: inputs, now: now, calendar: .current),
                       .available)
        let goal = PeriodGoal(metric: .vigorousMinutes, period: .week, target: 10)
        XCTAssertFalse(PeriodGoalTracker.restsWithoutAgeLess(goal, inputs: inputs))
        XCTAssertTrue(PeriodGoalTracker.restsWithoutAgeLess(goal, inputs: PeriodGoalInputs()), "AgeLess off: rests")
        XCTAssertFalse(PeriodGoalTracker.restsWithoutAgeLess(PeriodGoal(metric: .strengthMinutes, period: .week,
                                                                        target: 40), inputs: PeriodGoalInputs()))
    }

    /// The consistency goal averages the nightly scores AgeLess reads, carried as samples.
    func testSleepConsistencyAveragesTheNightlyScores() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        let samples = (0..<35).map { GoalMilestones.Sample(date: now.addingTimeInterval(-Double($0) * 86_400), value: 70) }
        let goal = CoachGoal(kind: .sleep, title: "Regular", baseline: 60, target: 80,
                             templateId: GoalTemplateID.sleepConsistency.rawValue,
                             measure: .init(metric: .sleepConsistency))
        let reading = LongTermGoalReader.reading(goal: goal, course: nil,
                                                 inputs: LongTermReaderInputs(series: [.sleepConsistency: samples]),
                                                 periodSnapshots: [], now: now, calendar: calendar)
        guard case .average(let data)? = reading else { return XCTFail("expected an average reading") }
        XCTAssertEqual(data.metric, .sleepConsistency)
        XCTAssertEqual(data.days.compactMap { $0 }.count, 28)
        XCTAssertEqual(GoalTemplateID.sleepConsistency.kind, .sleep)
    }
}
