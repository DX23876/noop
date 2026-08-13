import Foundation
import Combine
import WhoopStore

/// A repeatable, concrete action which can support several long-term goals without being duplicated.
/// Result progress (weight, distance, sleep) stays separate; this records execution only.
struct GoalAction: Codable, Identifiable, Equatable {
    enum Requirement: Codable, Equatable {
        case steps(minimum: Int)
        case workout(sports: [String], minimumMinutes: Int?)
        case manual

        var label: String {
            switch self {
            case .steps(let minimum): return "\(minimum.formatted()) steps"
            case .workout(let sports, let minutes):
                let activity = sports.isEmpty ? "Any workout" : sports.joined(separator: ", ")
                return minutes.map { "\(activity) · \($0) min" } ?? activity
            case .manual: return "Check off manually"
            }
        }
    }

    enum Schedule: Codable, Equatable {
        case daily
        /// Calendar weekday values (`1` Sunday ... `7` Saturday), kept sorted and unique by the editor.
        case weekdays([Int])

        func includes(_ date: Date, calendar: Calendar) -> Bool {
            switch self {
            case .daily: return true
            case .weekdays(let values): return values.contains(calendar.component(.weekday, from: date))
            }
        }
    }

    let id: UUID
    var title: String
    var requirement: Requirement
    var schedule: Schedule
    var goalIds: [UUID]
    var isActive: Bool
    let createdAt: Date

    init(id: UUID = UUID(), title: String, requirement: Requirement,
         schedule: Schedule = .daily, goalIds: [UUID], isActive: Bool = true,
         createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.requirement = requirement
        self.schedule = schedule
        var seen = Set<UUID>()
        self.goalIds = goalIds.filter { seen.insert($0).inserted }
        self.isActive = isActive
        self.createdAt = createdAt
    }
}

struct GoalActionCheckoff: Codable, Identifiable, Equatable {
    let actionId: UUID
    let day: String
    let completedAt: Date
    var id: String { "\(actionId.uuidString):\(day)" }
}

struct GoalActionOccurrence: Identifiable, Equatable {
    let action: GoalAction
    let day: String
    let isCompleted: Bool
    let isAutomatic: Bool
    var id: String { "\(action.id.uuidString):\(day)" }
}

struct GoalWorkoutContribution: Codable, Identifiable, Equatable {
    let workout: PlanWorkoutReference
    var goalIds: [UUID]
    let confirmedAt: Date
    var id: String { workout.workoutKey }
}

struct GoalWorkoutAttributionSuggestion: Identifiable, Equatable {
    let workout: PlanWorkoutReference
    let suggestedGoalIds: [UUID]
    var id: String { workout.workoutKey }
}

enum GoalActionEvaluator {
    static func occurrences(actions: [GoalAction], checkoffs: [GoalActionCheckoff],
                            activeGoalIds: Set<UUID>, days: [DailyMetric], workouts: [WorkoutRow],
                            from start: Date, through end: Date,
                            calendar: Calendar = .autoupdatingCurrent) -> [GoalActionOccurrence] {
        let dayMetrics = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, latest in latest })
        let manual = Set(checkoffs.map(\.id))
        let workoutsByDay = Dictionary(grouping: workouts) {
            dayKey(Date(timeIntervalSince1970: Double($0.startTs)), calendar: calendar)
        }
        var result: [GoalActionOccurrence] = []
        var cursor = calendar.startOfDay(for: start)
        let limit = calendar.startOfDay(for: end)
        while cursor <= limit {
            let key = dayKey(cursor, calendar: calendar)
            for action in actions where isDue(action, on: cursor, activeGoalIds: activeGoalIds,
                                               calendar: calendar) {
                let manualKey = "\(action.id.uuidString):\(key)"
                let automatic = automaticCompletion(action.requirement, metric: dayMetrics[key],
                                                    workouts: workoutsByDay[key] ?? [])
                result.append(.init(action: action, day: key,
                                    isCompleted: automatic || manual.contains(manualKey),
                                    isAutomatic: automatic))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }

    static func isDue(_ action: GoalAction, on date: Date, activeGoalIds: Set<UUID>,
                      calendar: Calendar = .autoupdatingCurrent) -> Bool {
        action.isActive
            && !activeGoalIds.isDisjoint(with: action.goalIds)
            && calendar.startOfDay(for: date) >= calendar.startOfDay(for: action.createdAt)
            && action.schedule.includes(date, calendar: calendar)
    }

    static func automaticCompletion(_ requirement: GoalAction.Requirement,
                                    metric: DailyMetric?, workouts: [WorkoutRow]) -> Bool {
        switch requirement {
        case .steps(let minimum):
            return (metric?.steps ?? 0) >= minimum
        case .manual:
            return false
        case .workout(let sports, let minimumMinutes):
            return workouts.contains { workout in
                let duration = workout.durationS ?? Double(max(0, workout.endTs - workout.startTs))
                let enoughDuration = minimumMinutes.map { duration >= Double($0 * 60) } ?? true
                return enoughDuration && matches(workout.sport, any: sports)
            }
        }
    }

    static func matches(_ activity: String, any requested: [String]) -> Bool {
        guard !requested.isEmpty else { return true }
        let actual = family(activity)
        return requested.contains { family($0) == actual }
    }

    private static func family(_ value: String) -> String {
        let text = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if text.contains("walk") || text.contains("hike") || text.contains("spazier") || text.contains("wander") {
            return "walking"
        }
        if text.contains("strength") || text.contains("weight") || text.contains("kraft")
            || text.contains("crossfit") { return "strength" }
        if text.contains("run") || text.contains("jog") || text.contains("lauf") { return "running" }
        if text.contains("cycle") || text.contains("bike") || text.contains("ride") || text.contains("rad") {
            return "cycling"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Conservative local suggestions. They are presentation defaults only: the user must save the
/// multi-selection before any relationship becomes part of tracking or coach context.
enum GoalAttributionSuggester {
    static func suggestedGoalIds(for activity: String, goals: [CoachGoal]) -> [UUID] {
        let familyMatches = goals.filter { goal in
            guard goal.status == .active else { return false }
            let lower = activity.lowercased()
            if lower.contains("walk") || lower.contains("spazier") || lower.contains("step") {
                return goal.kind == .consistency || goal.kind == .weight || goal.kind == .stress
                    || goal.kind == .recovery
                    || !Set(goal.motivationTags).isDisjoint(with: [.manageWeight, .feelHealthier,
                                                                   .moreEnergy, .lessExhausted])
            }
            if lower.contains("strength") || lower.contains("kraft") || lower.contains("weight") {
                return goal.kind == .strength || goal.kind == .consistency || goal.kind == .weight
                    || !Set(goal.motivationTags).isDisjoint(with: [.manageWeight, .feelHealthier,
                                                                   .performBetter])
            }
            if lower.contains("run") || lower.contains("lauf") {
                return goal.kind == .run || goal.kind == .consistency || goal.kind == .weight
            }
            return goal.kind == .consistency
        }
        return familyMatches.map(\.id)
    }
}

@MainActor
final class GoalActionStore: ObservableObject {
    static let shared = GoalActionStore()
    static let storageKey = "coach.goalActions.v1"

    private struct Payload: Codable { var actions: [GoalAction]; var checkoffs: [GoalActionCheckoff] }
    private let defaults: UserDefaults
    private let storageKey: String
    private var isLoading = true

    @Published private(set) var actions: [GoalAction] = [] { didSet { save() } }
    @Published private(set) var checkoffs: [GoalActionCheckoff] = [] { didSet { save() } }

    init(defaults: UserDefaults = .standard, storageKey: String = "coach.goalActions.v1",
         loading: Bool = true) {
        self.defaults = defaults
        self.storageKey = storageKey
        if loading, let data = defaults.data(forKey: storageKey),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            actions = payload.actions
            checkoffs = payload.checkoffs
        }
        isLoading = false
    }

    func upsert(_ action: GoalAction) {
        if let index = actions.firstIndex(where: { $0.id == action.id }) { actions[index] = action }
        else { actions.append(action) }
    }

    func remove(_ id: UUID) {
        actions.removeAll { $0.id == id }
        checkoffs.removeAll { $0.actionId == id }
    }

    func removeGoal(_ goalId: UUID) {
        actions = actions.compactMap { action in
            var copy = action
            copy.goalIds.removeAll { $0 == goalId }
            if copy.goalIds.isEmpty { copy.isActive = false }
            return copy
        }
    }

    func toggleManual(_ actionId: UUID, day: String, now: Date = Date()) {
        let id = "\(actionId.uuidString):\(day)"
        if checkoffs.contains(where: { $0.id == id }) { checkoffs.removeAll { $0.id == id } }
        else { checkoffs.append(.init(actionId: actionId, day: day, completedAt: now)) }
        trimCheckoffs()
    }

    private func trimCheckoffs() {
        if checkoffs.count > 1_000 {
            checkoffs = Array(checkoffs.sorted { $0.completedAt > $1.completedAt }.prefix(1_000))
        }
    }

    private func save() {
        guard !isLoading, let data = try? JSONEncoder().encode(Payload(actions: actions,
                                                                        checkoffs: checkoffs)) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

@MainActor
final class GoalContributionStore: ObservableObject {
    static let shared = GoalContributionStore()
    static let storageKey = "coach.goalContributions.v1"

    private struct Payload: Codable {
        var contributions: [GoalWorkoutContribution]
        var dismissedWorkoutKeys: [String]
    }
    private let defaults: UserDefaults
    private let storageKey: String
    private var isLoading = true

    @Published private(set) var contributions: [GoalWorkoutContribution] = [] { didSet { save() } }
    @Published private(set) var dismissedWorkoutKeys: Set<String> = [] { didSet { save() } }

    init(defaults: UserDefaults = .standard,
         storageKey: String = "coach.goalContributions.v1", loading: Bool = true) {
        self.defaults = defaults
        self.storageKey = storageKey
        if loading, let data = defaults.data(forKey: storageKey),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            contributions = payload.contributions
            dismissedWorkoutKeys = Set(payload.dismissedWorkoutKeys)
        }
        isLoading = false
    }

    func confirm(_ workout: PlanWorkoutReference, goalIds: [UUID], now: Date = Date()) {
        var seen = Set<UUID>()
        let unique = goalIds.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { dismiss(workout.workoutKey); return }
        let value = GoalWorkoutContribution(workout: workout, goalIds: unique, confirmedAt: now)
        if let index = contributions.firstIndex(where: { $0.id == value.id }) { contributions[index] = value }
        else { contributions.append(value) }
        dismissedWorkoutKeys.remove(workout.workoutKey)
    }

    func dismiss(_ workoutKey: String) {
        // The same action is also the explicit "supports none" edit for an existing attribution.
        contributions.removeAll { $0.id == workoutKey }
        dismissedWorkoutKeys.insert(workoutKey)
    }

    func removeGoal(_ goalId: UUID) {
        contributions = contributions.compactMap { item in
            var copy = item
            copy.goalIds.removeAll { $0 == goalId }
            return copy.goalIds.isEmpty ? nil : copy
        }
    }

    private func save() {
        guard !isLoading, let data = try? JSONEncoder().encode(Payload(
            contributions: contributions, dismissedWorkoutKeys: Array(dismissedWorkoutKeys))) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
