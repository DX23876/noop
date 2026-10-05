import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Catalog goals turned into their page's reading, one test per shape the walkthrough carries.
final class LongTermGoalReaderTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }()
    /// Wednesday 2026-10-07 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_374_400)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func run(_ daysAgo: Double, km: Double, sport: String = "Running", source: String = "apple_health") -> WorkoutRow {
        let start = Int(self.daysAgo(daysAgo).timeIntervalSince1970)
        return WorkoutRow(startTs: start, endTs: start + 1_800, sport: sport, source: source, durationS: 1_800,
                          energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: km * 1_000,
                          zonesJSON: nil, notes: nil, steps: nil)
    }

    private func night(_ daysAgo: Int, hours: Double) -> DailyMetric {
        let day = PeriodGoalTracker.dayKey(self.daysAgo(Double(daysAgo)), calendar: calendar)
        return DailyMetric(day: day, totalSleepMin: hours * 60, efficiency: nil, deepMin: nil, remMin: nil,
                           lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                           strain: nil, exerciseCount: nil)
    }

    // MARK: - Sum

    func testSumCountsOnlyTheChosenSportFromTheStart() throws {
        let goal = CoachGoal(kind: .endurance, title: "Run", baseline: 0, target: 1_000, targetDate: daysAgo(-90),
                             createdAt: daysAgo(5), templateId: GoalTemplateID.distanceTotal.rawValue,
                             measure: .init(metric: .distanceTotal, sportFilter: ["Running"], countFrom: daysAgo(60)))
        let inputs = LongTermReaderInputs(workouts: [run(10, km: 10), run(20, km: 12), run(30, km: 8),
                                                     run(15, km: 40, sport: "Cycling"), run(90, km: 21)])
        let reading = LongTermGoalReader.reading(goal: goal, course: nil, inputs: inputs, periodSnapshots: [],
                                                 now: now, calendar: calendar)
        guard case .sum(let data)? = reading else { return XCTFail("expected a sum reading") }
        XCTAssertEqual(data.reading.total, 30, accuracy: 1e-9, "cycling and the run before the start do not count")
        XCTAssertEqual(data.recentWeeks.count, 4)
        XCTAssertEqual(data.milestones?.next, 100)
        XCTAssertNotNil(reading?.state)
    }

    func testSumWithoutAnEndDateHasNoReading() {
        let goal = CoachGoal(kind: .endurance, title: "Run", target: 1_000,
                             templateId: GoalTemplateID.distanceTotal.rawValue, measure: .init(metric: .distanceTotal))
        XCTAssertNil(LongTermGoalReader.reading(goal: goal, course: nil, inputs: .init(), periodSnapshots: [],
                                                now: now, calendar: calendar))
    }

    // MARK: - Target value

    func testUndatedWeightGoalGetsItsRouteAndADirectionOnly() throws {
        let goal = CoachGoal(kind: .weight, title: "Get sexy", baseline: 217, target: 100,
                             templateId: GoalTemplateID.weightLose.rawValue, measure: .init(metric: .weight))
        let samples = (0..<28).map { GoalMilestones.Sample(date: daysAgo(Double(27 - $0)), value: 206 - Double($0) * 0.1) }
        let inputs = LongTermReaderInputs(weight: GoalMeasurement(value: 203.3, date: now), weightSamples: samples)
        let reading = LongTermGoalReader.reading(goal: goal, course: nil, inputs: inputs, periodSnapshots: [],
                                                 now: now, calendar: calendar)
        guard case .target(let data)? = reading else { return XCTFail("expected a target reading") }
        // A 117 kg route in whole kilos: the next mark below 203.3 is 203, not a 10 kg rung months away.
        XCTAssertEqual(data.milestones?.next, 203)
        XCTAssertEqual(data.milestones?.values.count, 117)
        XCTAssertEqual(data.state, .onTrack, "falling toward a lower target")
        XCTAssertEqual(data.ratePerWeek ?? 0, -0.7, accuracy: 1e-6)
        XCTAssertNotNil(data.nextMarkDate, "203 kg is days away at this pace")
        XCTAssertNil(data.arrivalDate, "100 kg is years away; no date is promised")
        XCTAssertEqual(data.progress, (217 - 203.3) / 117, accuracy: 1e-9)
    }

    /// The headline is the last weigh-in and milestones count the lowest one since the goal began, so a
    /// reading on the scale reaches its mark that day; the trend above it only judges the course.
    func testWeightMilestonesCountWhatTheScaleSaid() throws {
        let goal = CoachGoal(kind: .weight, title: "Get sexy", baseline: 217, target: 100, createdAt: daysAgo(60),
                             templateId: GoalTemplateID.weightLose.rawValue, measure: .init(metric: .weight))
        let readings = [(80.0, 216.0), (30.0, 209.6), (14.0, 209.3), (9.0, 210.5), (2.0, 207.3), (0.0, 208.1)]
            .map { GoalMilestones.Sample(date: daysAgo($0.0), value: $0.1) }
        let inputs = LongTermReaderInputs(weight: GoalMeasurement(value: 212.0, date: now),
                                          weightReadings: readings)
        let reading = LongTermGoalReader.reading(goal: goal, course: nil, inputs: inputs, periodSnapshots: [],
                                                 now: now, calendar: calendar)
        guard case .target(let data)? = reading else { return XCTFail("expected a target reading") }
        XCTAssertEqual(data.current, 208.1, "the last weigh-in, not the 212 kg trend")
        XCTAssertEqual(data.currentDate, daysAgo(0))
        XCTAssertEqual(data.milestones?.reachedCount, 9, "207.3 kg reached 216 down to 208; it stays reached")
        XCTAssertEqual(data.milestones?.next, 207)
        XCTAssertEqual(data.progress, (217 - 208.1) / 117, accuracy: 1e-9)
    }

    /// One weigh-in at the target reaches the goal, whatever the trend says.
    func testAWeighInAtTheTargetReachesTheGoal() {
        let goal = CoachGoal(kind: .weight, title: "Lighter", baseline: 90, target: 85, createdAt: daysAgo(40),
                             templateId: GoalTemplateID.weightLose.rawValue, measure: .init(metric: .weight))
        let readings = [(20.0, 88.0), (3.0, 84.8), (0.0, 85.6)].map { GoalMilestones.Sample(date: daysAgo($0.0), value: $0.1) }
        let inputs = LongTermReaderInputs(weight: GoalMeasurement(value: 86.9, date: now), weightReadings: readings)
        let reading = LongTermGoalReader.reading(goal: goal, course: nil, inputs: inputs, periodSnapshots: [],
                                                 now: now, calendar: calendar)
        XCTAssertEqual(reading?.state, .achieved)
    }

    func testProvisionalWeightIsShownNotJudged() {
        let goal = CoachGoal(kind: .weight, title: "Lighter", baseline: 90, target: 80,
                             templateId: GoalTemplateID.weightLose.rawValue, measure: .init(metric: .weight))
        let inputs = LongTermReaderInputs(weight: GoalMeasurement(value: 89, date: now, isProvisional: true))
        let reading = LongTermGoalReader.reading(goal: goal, course: nil, inputs: inputs, periodSnapshots: [],
                                                 now: now, calendar: calendar)
        XCTAssertEqual(reading?.state, .starting)
    }

    func testMaintainReadsTheBand() {
        let goal = CoachGoal(kind: .weight, title: "Keep", baseline: 80, target: 80,
                             templateId: GoalTemplateID.weightMaintain.rawValue,
                             measure: .init(metric: .weight, band: 1))
        let samples = [80.2, 80.6, 79.4, 82.0, 80.1].enumerated().map {
            GoalMilestones.Sample(date: daysAgo(Double(20 - $0.offset * 4)), value: $0.element)
        }
        let reading = LongTermGoalReader.reading(goal: goal, course: nil,
                                                 inputs: .init(weightSamples: samples), periodSnapshots: [],
                                                 now: now, calendar: calendar)
        guard case .maintain(let data)? = reading else { return XCTFail("expected a maintain reading") }
        XCTAssertEqual(data.reading.inBandShare ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(reading?.state, .onTrack)
    }

    // MARK: - Best value

    func testBestCountsTheChosenSportSinceTheGoalStarted() {
        let goal = CoachGoal(kind: .endurance, title: "10 km", baseline: 6, target: 10, createdAt: daysAgo(30),
                             templateId: GoalTemplateID.longest.rawValue,
                             measure: .init(metric: .longestDistance, sportFilter: ["Running"]))
        let inputs = LongTermReaderInputs(workouts: [run(60, km: 12), run(20, km: 7.5), run(10, km: 8.2),
                                                     run(5, km: 30, sport: "Cycling")])
        let reading = LongTermGoalReader.reading(goal: goal, course: nil, inputs: inputs, periodSnapshots: [],
                                                 now: now, calendar: calendar)
        guard case .best(let data)? = reading else { return XCTFail("expected a best reading") }
        XCTAssertEqual(data.reading.best ?? 0, 8.2, accuracy: 1e-9)
        XCTAssertEqual(data.reading.earlierBest ?? 0, 12, accuracy: 1e-9)
        XCTAssertNil(data.reading.state, "no date, nothing to call late")
        XCTAssertEqual(data.milestones?.next, 8.5)
    }

    // MARK: - Consistency

    func testConsistencyJudgesTheWeeklyGoalsWeeks() throws {
        let weeklyId = UUID()
        let goal = CoachGoal(kind: .consistency, title: "Strength", target: 3,
                             templateId: GoalTemplateID.trainingWeekly.rawValue,
                             measure: .init(metric: .weeklyAdherence, adherenceWeeks: 12, adherenceTarget: 0.8,
                                            weeklyGoalId: weeklyId))
        let outcomes: [PeriodOutcome] = [.missed] + Array(repeating: .achieved, count: 9) + [.protected, .achieved]
        let starts = (0..<12).map { PeriodGoalTracker.dayKey(daysAgo(Double((12 - $0) * 7)), calendar: calendar) }
        let history = zip(outcomes, starts).map {
            PeriodGoalSnapshot.HistoryEntry(periodStart: $0.1, target: 3, value: $0.0 == .achieved ? 3 : 1, outcome: $0.0)
        }
        let strength = (0..<6).map { run(Double($0 * 7 + 6), km: 0, sport: "Push Day", source: "hevy") }
        let reading = LongTermGoalReader.consistency(goal: goal, spec: goal.measure!, weeklyGoalId: weeklyId,
                                                     history: history, thisWeek: 2, weeklyTarget: 3,
                                                     workouts: strength, now: now, calendar: calendar)
        guard case .consistency(let data) = reading else { return XCTFail("expected a consistency reading") }
        XCTAssertEqual(data.reading.hit, 10)
        XCTAssertEqual(data.reading.evaluated, 11)
        XCTAssertEqual(reading.state, .onTrack)
        XCTAssertEqual(data.lastWeeks.count, 8)
        XCTAssertEqual(data.lastWeekStarts.count, 8)
        XCTAssertEqual(data.strongestWeekday, 5, "every session fell on a Thursday")
    }

    func testFixedEndIsJudgedOnce() {
        let weeklyId = UUID()
        let goal = CoachGoal(kind: .consistency, title: "12 weeks", target: 3, createdAt: daysAgo(100),
                             templateId: GoalTemplateID.trainingWeekly.rawValue,
                             measure: .init(metric: .weeklyAdherence, adherenceTarget: 0.8,
                                            fixedEnd: daysAgo(1), weeklyGoalId: weeklyId))
        let history = (0..<12).map {
            PeriodGoalSnapshot.HistoryEntry(periodStart: PeriodGoalTracker.dayKey(daysAgo(Double((12 - $0) * 7)), calendar: calendar),
                                            target: 3, value: $0 < 4 ? 1 : 3, outcome: $0 < 4 ? .missed : .achieved)
        }
        let reading = LongTermGoalReader.consistency(goal: goal, spec: goal.measure!, weeklyGoalId: weeklyId,
                                                     history: history, thisWeek: 0, weeklyTarget: 3,
                                                     workouts: [], now: now, calendar: calendar)
        XCTAssertEqual(reading.state, .outOfReach, "8 of 12 weeks is below 80 %")
    }

    // MARK: - Average

    func testSleepAverageOverTwentyEightNights() throws {
        let goal = CoachGoal(kind: .sleep, title: "Sleep", baseline: 6.8, target: 7.5,
                             templateId: GoalTemplateID.sleepAverage.rawValue, measure: .init(metric: .sleepAverage))
        let nights = (0..<56).map { night($0, hours: 7.6 - Double($0) * 0.02) }
        let reading = LongTermGoalReader.reading(goal: goal, course: nil, inputs: .init(days: nights),
                                                 periodSnapshots: [], now: now, calendar: calendar)
        guard case .average(let data)? = reading else { return XCTFail("expected an average reading") }
        XCTAssertEqual(data.days.count, 28)
        XCTAssertEqual(data.reading.values, 28)
        XCTAssertEqual(reading?.state, .onTrack, "below 7.5 h on average, rising")
        XCTAssertNotNil(data.bestWeekMean)
    }

    // MARK: - Other target values

    /// Resting heart rate: four weeks of nights are the level, so a target counts as reached only once it
    /// holds; falling toward a lower target is on track.
    func testRestingHeartRateReadsTheWeekMeanAndItsDirection() throws {
        let goal = CoachGoal(kind: .fitness, title: "Calmer heart", baseline: 58, target: 52,
                             templateId: GoalTemplateID.restingHr.rawValue, measure: .init(metric: .restingHr))
        // 56 nights falling from 58 to 55 bpm.
        let nights = (0..<56).map { GoalMilestones.Sample(date: daysAgo(Double(55 - $0)), value: 58 - Double($0) * 3 / 55) }
        let reading = LongTermGoalReader.reading(goal: goal, course: nil,
                                                 inputs: LongTermReaderInputs(series: [.restingHr: nights]),
                                                 periodSnapshots: [], now: now, calendar: calendar)
        guard case .target(let data)? = reading else { return XCTFail("expected a target reading") }
        XCTAssertEqual(data.metric, .restingHr)
        let lastFourWeeks = nights.suffix(28).map(\.value).reduce(0, +) / 28
        XCTAssertEqual(data.current, lastFourWeeks, accuracy: 1e-9)
        XCTAssertFalse(data.isProvisional)
        XCTAssertEqual(data.state, .onTrack)
        XCTAssertLessThan(data.ratePerWeek ?? 0, 0)
    }

    /// A tape measure is read like the scale: 110 cm today is the headline and counts for the marks,
    /// not the 112 cm average with last month's 114 cm.
    func testWaistCountsTheLatestMeasurement() throws {
        let goal = CoachGoal(kind: .weight, title: "Slimmer", baseline: 116, target: 100, createdAt: daysAgo(60),
                             templateId: GoalTemplateID.waist.rawValue, measure: .init(metric: .waist))
        let tape = [GoalMilestones.Sample(date: daysAgo(21), value: 114), GoalMilestones.Sample(date: daysAgo(0), value: 110)]
        let reading = LongTermGoalReader.reading(goal: goal, course: nil,
                                                 inputs: LongTermReaderInputs(series: [.waist: tape]),
                                                 periodSnapshots: [], now: now, calendar: calendar)
        guard case .target(let data)? = reading else { return XCTFail("expected a target reading") }
        XCTAssertEqual(data.current, 110)
        XCTAssertEqual(data.currentDate, daysAgo(0))
        let expected = LongTermGoalMath.milestoneWindow(
            baseline: 116, target: 100, current: 110,
            preferredCount: min(LongTermGoalMath.undatedPreferredCount, 16))
        XCTAssertEqual(data.milestones?.reachedCount, expected?.reachedCount)
    }

    /// A drift below half a beat a month is no direction: the goal runs, it is neither on track nor
    /// behind, and its waypoints are whole beats.
    func testFlatRestingHeartRateIsNeitherOnTrackNorBehind() throws {
        let goal = CoachGoal(kind: .fitness, title: "Calmer heart", baseline: 56, target: 53,
                             templateId: GoalTemplateID.restingHr.rawValue, measure: .init(metric: .restingHr))
        let nights = (0..<56).map { GoalMilestones.Sample(date: daysAgo(Double(55 - $0)), value: 56 + Double($0 % 3) * 0.2) }
        let reading = LongTermGoalReader.reading(goal: goal, course: nil,
                                                 inputs: LongTermReaderInputs(series: [.restingHr: nights]),
                                                 periodSnapshots: [], now: now, calendar: calendar)
        guard case .target(let data)? = reading else { return XCTFail("expected a target reading") }
        XCTAssertNil(data.state)
        XCTAssertEqual(data.ratePerWeek, 0)
        XCTAssertEqual(data.milestones?.values, [55, 54, 53])
    }

    /// A body measurement taken twice is shown but not judged; the first reading alone is provisional.
    func testSparseBodyMeasurementIsProvisional() throws {
        let goal = CoachGoal(kind: .body, title: "Waist", baseline: 92, target: 86,
                             templateId: GoalTemplateID.waist.rawValue, measure: .init(metric: .waist))
        let one = [GoalMilestones.Sample(date: daysAgo(3), value: 91)]
        let reading = LongTermGoalReader.reading(goal: goal, course: nil,
                                                 inputs: LongTermReaderInputs(series: [.waist: one]),
                                                 periodSnapshots: [], now: now, calendar: calendar)
        guard case .target(let data)? = reading else { return XCTFail("expected a target reading") }
        XCTAssertEqual(data.current, 91, accuracy: 1e-9)
        XCTAssertTrue(data.isProvisional)
        XCTAssertEqual(data.state, .starting)
    }

    /// "Run faster": lower is better, the band is one column per qualifying run.
    func testPaceGoalReadsRunsFromThreeKilometres() throws {
        let goal = CoachGoal(kind: .run, title: "Faster", baseline: 330, target: 300,
                             templateId: GoalTemplateID.paceAverage.rawValue, measure: .init(metric: .paceAverage))
        // Four 5 km runs in 30 minutes (360 s/km) and one 2 km jog that does not count.
        let runs = [run(2, km: 5), run(9, km: 5), run(16, km: 5), run(23, km: 5), run(5, km: 2)]
        let reading = LongTermGoalReader.reading(goal: goal, course: nil,
                                                 inputs: LongTermReaderInputs(workouts: runs),
                                                 periodSnapshots: [], now: now, calendar: calendar)
        guard case .average(let data)? = reading else { return XCTFail("expected an average reading") }
        XCTAssertFalse(data.higherIsBetter)
        XCTAssertEqual(data.reading.mean ?? 0, 360, accuracy: 1e-9)
        XCTAssertEqual(data.days.count, 4)
        XCTAssertEqual(data.reading.gap ?? 0, 60, accuracy: 1e-9)
    }

    // MARK: - Sport matching

    func testHevySessionsCountAsStrengthWhateverTheirName() {
        let push = run(1, km: 0, sport: "Push Day", source: "hevy")
        let walk = run(1, km: 2, sport: "Walking")
        XCTAssertTrue(GoalActionEvaluator.matches(push, any: ["Strength"]))
        XCTAssertFalse(GoalActionEvaluator.matches(walk, any: ["Strength"]))
        XCTAssertTrue(GoalActionEvaluator.matches(run(1, km: 1, sport: "Pool Swim"), any: ["Swimming"]))
    }
}
