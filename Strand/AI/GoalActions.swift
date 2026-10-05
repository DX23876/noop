import Foundation
import Combine
import WhoopStore

/// A repeatable, concrete action which can support several long-term goals without being duplicated.
/// Result progress (weight, distance, sleep) stays separate; this records execution only.
struct GoalAction: Codable, Identifiable, Equatable {
    enum Requirement: Codable, Equatable {
        case steps(minimum: Int)
        case workout(sports: [String], minimumMinutes: Int?)
        /// Nightly sleep. Reads `DailyMetric.totalSleepMin`, the same number the Sleep screen shows.
        case sleep(minimumHours: Double)
        /// Active energy. NOOP's own figure is an HR-only ESTIMATE (`activeKcalEst`), so the label
        /// says so — an action that silently treats an estimate as measured would be the wrong kind
        /// of confident.
        case activeCalories(minimum: Int)
        case manual
        /// A box ticked by the journal: done the day `question` is logged with `wantsYes` ("Meditation"
        /// logged yes, "Alcohol" logged no). Nothing logged is not done; the next-day question asks.
        case journal(question: String, wantsYes: Bool)

        var label: String {
            switch self {
            case .steps(let minimum): return "\(minimum.formatted()) steps"
            case .workout(let sports, let minutes):
                let activity = sports.isEmpty ? "Any workout" : sports.joined(separator: ", ")
                return minutes.map { "\(activity) · \($0) min" } ?? activity
            case .sleep(let hours):
                return String(format: "%.1f h sleep", hours).replacingOccurrences(of: ".0 h", with: " h")
            case .activeCalories(let minimum): return "\(minimum.formatted()) kcal active (estimate)"
            case .manual: return "Check off manually"
            case .journal(let question, let wantsYes):
                return wantsYes ? "Logged in the journal: \(question)" : "Logged as no in the journal: \(question)"
            }
        }

        /// `label` in the reader's language. The English `label` stays for anything that is not UI; a
        /// composed English string cannot be looked up in the catalog afterwards, so each part is
        /// localized here with its own key.
        var displayLabel: String {
            switch self {
            case .steps(let minimum): return String(localized: "\(minimum.formatted()) steps")
            case .workout(let sports, let minutes):
                let activity = sports.isEmpty ? String(localized: "Any workout") : sports.joined(separator: ", ")
                return minutes.map { String(localized: "\(activity) · \($0) min") } ?? activity
            case .sleep(let hours):
                return String(localized: "\(hours.formatted(.number.precision(.fractionLength(0...1)))) h sleep")
            case .activeCalories(let minimum):
                return String(localized: "\(minimum.formatted()) kcal active (estimate)")
            // Nothing to say: ticking a box by hand is what a goal without a measure is.
            case .manual: return ""
            case .journal(let question, let wantsYes):
                let habit = JournalLabel.display(question)
                return wantsYes ? String(localized: "Ticks when you log yes: \(habit)")
                                : String(localized: "Ticks when you log no: \(habit)")
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
    /// The last day (local day key, inclusive) a daily goal asks for; nil runs without end (Q25).
    /// "Only today" is a goal whose last day is the day it was set. Optional, so stored goals and
    /// backups from before it decode unchanged.
    var endsOn: String?
    /// Whether a measured daily goal is drawn as one of the (at most three) rings. nil = automatic: the
    /// first three in the fixed order. false keeps it in the count below the rings (plan §17g).
    var showsAsRing: Bool?

    init(id: UUID = UUID(), title: String, requirement: Requirement,
         schedule: Schedule = .daily, goalIds: [UUID], isActive: Bool = true,
         createdAt: Date = Date(), endsOn: String? = nil, showsAsRing: Bool? = nil) {
        self.id = id
        self.title = title
        self.requirement = requirement
        self.schedule = schedule
        var seen = Set<UUID>()
        self.goalIds = goalIds.filter { seen.insert($0).inserted }
        self.isActive = isActive
        self.createdAt = createdAt
        self.endsOn = endsOn
        self.showsAsRing = showsAsRing
    }

    /// Past its last day: it no longer shows as due and moves to the ended goals.
    func hasEnded(today: String) -> Bool {
        guard let endsOn else { return false }
        return today > endsOn
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
    /// How far a measured daily goal has come today (steps walked, hours slept, kcal), in the
    /// requirement's own unit. nil for workout and manual goals, which are done or not.
    var measured: Double? = nil
    var id: String { "\(action.id.uuidString):\(day)" }

    /// The requirement's target in the same unit as `measured`.
    var measuredTarget: Double? {
        switch action.requirement {
        case .steps(let minimum): return Double(minimum)
        case .sleep(let hours): return hours
        case .activeCalories(let minimum): return Double(minimum)
        // A workout with a minimum length fills up in minutes; one without is done or not.
        case .workout(_, let minutes): return minutes.map(Double.init)
        case .manual, .journal: return nil
        }
    }

    /// Done so far as a share of the target, for the ring beside a daily goal.
    var fraction: Double? {
        guard let measured, let target = measuredTarget, target > 0 else { return nil }
        return measured / target
    }
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
                            activeKcalByDay: [String: Double] = [:],
                            stepsByDay: [String: Int] = [:],
                            journalByDay: [String: [JournalEntry]] = [:],
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
                                                    workouts: workoutsByDay[key] ?? [],
                                                    activeKcal: activeKcalByDay[key],
                                                    steps: stepsByDay[key],
                                                    journal: journalByDay[key] ?? [])
                result.append(.init(action: action, day: key,
                                    isCompleted: automatic || manual.contains(manualKey),
                                    isAutomatic: automatic,
                                    measured: measuredValue(action.requirement, metric: dayMetrics[key],
                                                            activeKcal: activeKcalByDay[key],
                                                            steps: stepsByDay[key],
                                                            workouts: workoutsByDay[key] ?? [])))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }

    /// The day's reading for a measured requirement, in its own unit; nil when nothing was measured
    /// or the requirement is not a number (a workout, a manual box).
    static func measuredValue(_ requirement: GoalAction.Requirement, metric: DailyMetric?,
                              activeKcal: Double?, steps: Int? = nil, workouts: [WorkoutRow] = []) -> Double? {
        switch requirement {
        case .workout(let sports, let minimumMinutes?) where minimumMinutes > 0:
            // The longest matching workout, in minutes: the same rule `automaticCompletion` ticks the goal
            // by (one workout long enough), so a full ring and a ticked goal always agree.
            let longest = workouts.filter { matches($0.sport, any: sports) }
                .map { ($0.durationS ?? Double(max(0, $0.endTs - $0.startTs))) / 60 }.max()
            return longest ?? 0
        case .steps: return (metric?.steps ?? steps).map(Double.init)
        case .sleep: return metric?.totalSleepMin.map { Double($0) / 60 }
        case .activeCalories: return activeKcal
        case .workout, .manual, .journal: return nil
        }
    }

    static func isDue(_ action: GoalAction, on date: Date, activeGoalIds: Set<UUID>,
                      calendar: Calendar = .autoupdatingCurrent) -> Bool {
        // A daily goal that serves no long-term goal stands on its own (Q21, e.g. the step goal);
        // one linked to goals is due only while at least one of them is active.
        action.isActive
            && (action.goalIds.isEmpty || !activeGoalIds.isDisjoint(with: action.goalIds))
            && calendar.startOfDay(for: date) >= calendar.startOfDay(for: action.createdAt)
            && (action.endsOn.map { dayKey(date, calendar: calendar) <= $0 } ?? true)
            && action.schedule.includes(date, calendar: calendar)
    }

    /// `activeKcal` is the day's active energy from the energy model (`Repository.activeEnergyByDay`),
    /// the figure the Energy screen shows; the retired `activeKcalEst` included basal.
    static func automaticCompletion(_ requirement: GoalAction.Requirement,
                                    metric: DailyMetric?, workouts: [WorkoutRow],
                                    activeKcal: Double? = nil, steps: Int? = nil,
                                    journal: [JournalEntry] = []) -> Bool {
        switch requirement {
        case .steps(let minimum):
            // The strap's own count first, then the same day's measured count from Health: the rule
            // Today's step card uses (`DailyStepsReading`), never the motion estimate.
            return (metric?.steps ?? steps ?? 0) >= minimum
        case .sleep(let hours):
            guard let minutes = metric?.totalSleepMin else { return false }
            return minutes >= hours * 60
        case .activeCalories(let minimum):
            guard let kcal = activeKcal else { return false }
            return kcal >= Double(minimum)
        case .manual:
            return false
        case .journal(let question, let wantsYes):
            return journal.contains { $0.question == question && $0.answeredYes == wantsYes }
        case .workout(let sports, let minimumMinutes):
            return workouts.contains { workout in
                let duration = workout.durationS ?? Double(max(0, workout.endTs - workout.startTs))
                let enoughDuration = minimumMinutes.map { duration >= Double($0 * 60) } ?? true
                return enoughDuration && matches(workout.sport, any: sports)
            }
        }
    }

    /// Daily actions worth offering for a given goal, most relevant first.
    ///
    /// The alternative — one long fixed list — makes the user do the matching. A weight goal is served
    /// by moving and by training; a sleep goal by a sleep floor. Every suggestion here is something
    /// NOOP can actually CHECK, so an accepted suggestion completes itself rather than becoming
    /// another box to tick by hand.
    ///
    /// Pure and side-effect free, so the mapping is testable without a view.
    static func suggestions(for kind: CoachGoal.Kind) -> [GoalAction.Requirement] {
        switch kind {
        case .weight:
            return [.steps(minimum: 8_000), .workout(sports: [], minimumMinutes: 30),
                    .activeCalories(minimum: 500)]
        case .consistency:
            return [.workout(sports: [], minimumMinutes: 30), .steps(minimum: 8_000)]
        case .run:
            return [.workout(sports: ["Running"], minimumMinutes: 30), .steps(minimum: 8_000)]
        case .strength, .hardSets:
            // The same daily offer for both strength kinds: what NOOP can check on a DAY is that a
            // lifting session happened. The sets themselves are counted weekly by goal tracking, and a
            // daily "did you do 3 sets" check would be a smaller claim than the goal makes.
            return [.workout(sports: ["Strength"], minimumMinutes: 30)]
        case .sleep:
            return [.sleep(minimumHours: 7.5)]
        case .stress, .recovery:
            // Nothing NOOP measures makes an honest DAILY check for these; a manual note is the
            // truthful offer rather than a proxy dressed up as the goal.
            return [.manual]
        case .custom:
            return [.manual]
        case .endurance:
            return [.workout(sports: [], minimumMinutes: 30), .steps(minimum: 8_000)]
        case .fitness:
            return [.workout(sports: [], minimumMinutes: 30)]
        case .body:
            return [.steps(minimum: 8_000), .workout(sports: [], minimumMinutes: 30)]
        case .activity:
            return [.steps(minimum: 8_000)]
        case .habit:
            return [.manual]
        }
    }

    static func matches(_ activity: String, any requested: [String]) -> Bool {
        guard !requested.isEmpty else { return true }
        let actual = family(activity)
        return requested.contains { family($0) == actual }
    }

    /// A workout against a sport filter. Like `matches(_:any:)`, plus one thing the name cannot tell: a
    /// session from Hevy or the lifting import is strength training whatever it is called ("Push Day"),
    /// the same rule the long-term strength goal reads by (plan Q18).
    static func matches(_ row: WorkoutRow, any requested: [String]) -> Bool {
        if matches(row.sport, any: requested) { return true }
        guard requested.contains(where: { family($0) == "strength" }) else { return false }
        switch WorkoutSource.classify(row.source) {
        case .hevy, .lifting: return true
        default: return false
        }
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
        if text.contains("swim") || text.contains("schwimm") { return "swimming" }
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
        syncStepGoal()
    }

    /// The standalone daily step goal, if there is one. Momentum's step goal reads from it (Q8).
    var dailyStepGoal: GoalAction? {
        let today = GoalActionEvaluator.dayKey(Date(), calendar: .autoupdatingCurrent)
        return actions.first { action in
            guard action.isActive, action.goalIds.isEmpty, !action.hasEnded(today: today),
                  case .steps = action.requirement else { return false }
            return true
        }
    }

    static let stepGoalMigratedKey = "goals.stepGoalMigrated"

    /// One-time: the step goal Momentum kept on its own becomes a daily goal, so there is one step goal
    /// in the app. Afterwards Momentum's value follows the daily goal.
    func migrateMomentumStepGoalIfNeeded() {
        guard !defaults.bool(forKey: Self.stepGoalMigratedKey) else { return }
        defaults.set(true, forKey: Self.stepGoalMigratedKey)
        let legacy = defaults.integer(forKey: "momentum.stepGoal")
        guard legacy > 0, dailyStepGoal == nil else { return }
        actions.append(GoalAction(title: String(localized: "Daily steps"), requirement: .steps(minimum: legacy),
                                  goalIds: []))
    }

    /// Keeps Momentum's step goal equal to the daily step goal, the single source of truth.
    func syncStepGoal() {
        guard let goal = dailyStepGoal, case .steps(let minimum) = goal.requirement else { return }
        if defaults.integer(forKey: "momentum.stepGoal") != minimum {
            defaults.set(minimum, forKey: "momentum.stepGoal")
        }
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
