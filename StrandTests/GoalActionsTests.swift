import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class GoalActionsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    private func date(_ value: String) -> Date {
        let parts = value.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    private func metric(_ day: String, steps: Int?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: nil, strain: nil, exerciseCount: nil, steps: steps)
    }

    private func workout(_ day: String, sport: String, minutes: Int) -> WorkoutRow {
        let start = Int(date(day).timeIntervalSince1970)
        return WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: sport,
                          source: "test", durationS: Double(minutes * 60), energyKcal: nil,
                          avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                          zonesJSON: nil, notes: nil)
    }

    func testStepActionCompletesAutomaticallyAtThreshold() {
        let goal = UUID()
        let action = GoalAction(title: "10,000 steps", requirement: .steps(minimum: 10_000),
                                goalIds: [goal], createdAt: date("2026-08-01"))

        let occurrences = GoalActionEvaluator.occurrences(
            actions: [action], checkoffs: [], activeGoalIds: [goal],
            days: [metric("2026-08-10", steps: 10_250)], workouts: [],
            from: date("2026-08-10"), through: date("2026-08-10"), calendar: calendar)

        XCTAssertEqual(occurrences.count, 1)
        XCTAssertTrue(occurrences[0].isCompleted)
        XCTAssertTrue(occurrences[0].isAutomatic)
    }

    func testWorkoutActionUsesSportFamilyAndMinimumDuration() {
        let goal = UUID()
        let action = GoalAction(title: "Go for a walk",
                                requirement: .workout(sports: ["Walking"], minimumMinutes: 20),
                                goalIds: [goal], createdAt: date("2026-08-01"))
        let rows = [workout("2026-08-10", sport: "Spaziergang", minutes: 25)]

        let occurrences = GoalActionEvaluator.occurrences(
            actions: [action], checkoffs: [], activeGoalIds: [goal], days: [], workouts: rows,
            from: date("2026-08-10"), through: date("2026-08-10"), calendar: calendar)

        XCTAssertTrue(occurrences[0].isCompleted)
        XCTAssertTrue(occurrences[0].isAutomatic)
    }

    func testShortWorkoutDoesNotMeetMinimumDuration() {
        let goal = UUID()
        let action = GoalAction(title: "Strength",
                                requirement: .workout(sports: ["Strength"], minimumMinutes: 30),
                                goalIds: [goal], createdAt: date("2026-08-01"))

        let occurrences = GoalActionEvaluator.occurrences(
            actions: [action], checkoffs: [], activeGoalIds: [goal], days: [],
            workouts: [workout("2026-08-10", sport: "Krafttraining", minutes: 20)],
            from: date("2026-08-10"), through: date("2026-08-10"), calendar: calendar)

        XCTAssertFalse(occurrences[0].isCompleted)
    }

    func testWeekdayScheduleOnlyCreatesDueOccurrences() {
        let goal = UUID()
        let action = GoalAction(title: "Weekday walk", requirement: .manual,
                                schedule: .weekdays([2, 4]), goalIds: [goal],
                                createdAt: date("2026-08-01"))

        let occurrences = GoalActionEvaluator.occurrences(
            actions: [action], checkoffs: [], activeGoalIds: [goal], days: [], workouts: [],
            from: date("2026-08-10"), through: date("2026-08-16"), calendar: calendar)

        XCTAssertEqual(occurrences.map(\.day), ["2026-08-10", "2026-08-12"])
    }

    func testOneSharedActionProducesOneOccurrenceAndServesBothGoals() {
        let movement = UUID(), mood = UUID()
        let action = GoalAction(title: "Walk", requirement: .manual,
                                goalIds: [movement, mood], createdAt: date("2026-08-01"))

        let occurrences = GoalActionEvaluator.occurrences(
            actions: [action], checkoffs: [], activeGoalIds: [movement, mood], days: [], workouts: [],
            from: date("2026-08-10"), through: date("2026-08-10"), calendar: calendar)

        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(Set(occurrences[0].action.goalIds), Set([movement, mood]))
    }

    func testManualCheckoffPersistsAndCanBeToggledOff() {
        let suite = "GoalActions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let goal = UUID()
        let action = GoalAction(title: "Stretch", requirement: .manual, goalIds: [goal])
        let first = GoalActionStore(defaults: defaults, storageKey: "actions")
        first.upsert(action)
        first.toggleManual(action.id, day: "2026-08-10", now: date("2026-08-10"))

        let reloaded = GoalActionStore(defaults: defaults, storageKey: "actions")
        XCTAssertEqual(reloaded.actions, [action])
        XCTAssertEqual(reloaded.checkoffs.count, 1)

        reloaded.toggleManual(action.id, day: "2026-08-10")
        XCTAssertTrue(reloaded.checkoffs.isEmpty)
    }

    func testContributionCanLinkOneWorkoutToSeveralGoalsAndBeEdited() {
        let suite = "GoalContributions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        let reference = PlanWorkoutReference(workout("2026-08-10", sport: "Walking", minutes: 30))
        let store = GoalContributionStore(defaults: defaults, storageKey: "contributions")

        store.confirm(reference, goalIds: [first, second, first], now: date("2026-08-10"))
        store.confirm(reference, goalIds: [second], now: date("2026-08-11"))

        XCTAssertEqual(store.contributions.count, 1)
        XCTAssertEqual(store.contributions[0].goalIds, [second])
        XCTAssertFalse(store.dismissedWorkoutKeys.contains(reference.workoutKey))

        store.dismiss(reference.workoutKey)
        XCTAssertTrue(store.contributions.isEmpty)
        XCTAssertTrue(store.dismissedWorkoutKeys.contains(reference.workoutKey))
    }
}
