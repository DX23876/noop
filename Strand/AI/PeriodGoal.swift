import Foundation
import Combine
import StrandAnalytics

/// What a weekly or monthly goal measures. Every case is something NOOP can actually read; a metric is
/// only offered once its source has delivered data (see `PeriodGoalTracker.availableMetrics`).
enum PeriodMetric: String, Codable, CaseIterable, Identifiable {
    case workouts          // number of workouts
    case trainingMinutes   // minutes of training
    case distance          // kilometres (running by default)
    case stepDays          // days with at least N steps
    case sleepNights       // nights of at least N hours
    case sleepAverage      // average nightly sleep
    case zoneMinutes       // minutes in heart-rate zone 2 and above
    case workingSets       // working sets from the lifting log
    case activeEnergy      // active kcal (an estimate)
    case restDays          // days without a workout
    case hydrationDays     // days the drinking goal was reached
    case habitDays         // days a journal habit was kept

    var id: String { rawValue }

    var aggregation: PeriodAggregation {
        switch self {
        case .workouts: return .count
        case .trainingMinutes, .distance, .zoneMinutes, .workingSets, .activeEnergy: return .sum
        case .stepDays, .sleepNights, .restDays, .hydrationDays, .habitDays: return .hitDays
        case .sleepAverage: return .average
        }
    }

    /// Short name, catalog key.
    var label: String {
        switch self {
        case .workouts:        return "Workouts"
        case .trainingMinutes: return "Training minutes"
        case .distance:        return "Distance"
        case .stepDays:        return "Step days"
        case .sleepNights:     return "Nights of enough sleep"
        case .sleepAverage:    return "Average sleep"
        case .zoneMinutes:     return "Zone 2+ minutes"
        case .workingSets:     return "Working sets"
        case .activeEnergy:    return "Active energy"
        case .restDays:        return "Rest days"
        case .hydrationDays:   return "Hydration days"
        case .habitDays:       return "Habit days"
        }
    }

    /// One line under the label in pickers, catalog key.
    var blurb: String {
        switch self {
        case .workouts:        return "Count the sessions you do."
        case .trainingMinutes: return "Add up the time you train."
        case .distance:        return "Add up the kilometres you cover."
        case .stepDays:        return "Days you reach a step count."
        case .sleepNights:     return "Nights you sleep long enough."
        case .sleepAverage:    return "Your mean nightly sleep."
        case .zoneMinutes:     return "Minutes in heart-rate zone 2 and above."
        case .workingSets:     return "Working sets from your lifting log."
        case .activeEnergy:    return "Active calories, as NOOP estimates them."
        case .restDays:        return "Days you give your body off."
        case .hydrationDays:   return "Days you reach your drinking goal."
        case .habitDays:       return "Days you keep a journal habit."
        }
    }

    var icon: String {
        switch self {
        case .workouts:        return "figure.mixed.cardio"
        case .trainingMinutes: return "timer"
        case .distance:        return "point.topleft.down.to.point.bottomright.curvepath"
        case .stepDays:        return "figure.walk"
        case .sleepNights:     return "moon.stars.fill"
        case .sleepAverage:    return "bed.double.fill"
        case .zoneMinutes:     return "heart.fill"
        case .workingSets:     return "dumbbell.fill"
        case .activeEnergy:    return "flame.fill"
        case .restDays:        return "leaf.fill"
        case .hydrationDays:   return "drop.fill"
        case .habitDays:       return "checklist"
        }
    }

    /// The identity colour key (Apple-inspired colours), shared with the long-term goal of the same idea.
    var colorKey: String {
        switch self {
        case .workouts, .trainingMinutes:      return "coach.goal.consistency"
        case .distance:                        return "coach.goal.run"
        case .zoneMinutes:                     return "goal.zoneMinutes"
        case .stepDays:                        return "coach.goal.weight"
        case .activeEnergy:                    return "goal.activeEnergy"
        case .hydrationDays:                   return "goal.hydration"
        case .sleepNights, .sleepAverage:      return "coach.goal.sleep"
        case .workingSets:                     return "coach.goal.strength"
        case .restDays:                        return "goal.restDays"
        case .habitDays:                       return "coach.goal.custom"
        }
    }

    /// Training goals share their pace only over training days; the central rest days apply to them.
    var usesRestDays: Bool {
        switch self {
        case .workouts, .trainingMinutes, .distance, .zoneMinutes, .workingSets: return true
        default: return false
        }
    }

    /// Whether the goal carries a per-day threshold (steps, hours) rather than only a target.
    var hasThreshold: Bool { self == .stepDays || self == .sleepNights }

    /// Whether workouts can be filtered by sport.
    var hasSportFilter: Bool { self == .workouts || self == .trainingMinutes || self == .distance }

    /// Whether the goal is fed by individual workouts (and so has "what counted" with corrections).
    var isWorkoutBased: Bool {
        switch self {
        case .workouts, .trainingMinutes, .distance, .zoneMinutes: return true
        default: return false
        }
    }

    /// The smallest sensible change of the target.
    func step(for period: PeriodGoal.Period) -> Double {
        switch self {
        case .workouts, .stepDays, .sleepNights, .restDays, .hydrationDays, .habitDays: return 1
        case .trainingMinutes, .zoneMinutes: return period == .week ? 15 : 30
        case .distance:        return period == .week ? 1 : 5
        case .sleepAverage:    return 0.25
        case .workingSets:     return 5
        case .activeEnergy:    return period == .week ? 250 : 1000
        }
    }

    func range(for period: PeriodGoal.Period, days: Int = 7) -> ClosedRange<Double> {
        let month = period == .month
        switch self {
        case .workouts:        return 1...(month ? 60 : 14)
        case .trainingMinutes: return 15...(month ? 6000 : 1500)
        case .distance:        return 1...(month ? 1000 : 250)
        case .stepDays, .sleepNights, .restDays, .hydrationDays, .habitDays:
            return 1...Double(month ? 31 : 7)
        case .sleepAverage:    return 5...10
        case .zoneMinutes:     return 15...(month ? 6000 : 1500)
        case .workingSets:     return 5...(month ? 1000 : 250)
        case .activeEnergy:    return 250...(month ? 60000 : 15000)
        }
    }

    /// A starting value when there is no history to recommend from.
    func defaultTarget(for period: PeriodGoal.Period) -> Double {
        let week: Double
        switch self {
        case .workouts:        week = 3
        case .trainingMinutes: week = 150
        case .distance:        week = 10
        case .stepDays:        week = 5
        case .sleepNights:     week = 5
        case .sleepAverage:    return 7.5
        case .zoneMinutes:     week = 150
        case .workingSets:     week = 40
        case .activeEnergy:    week = 2500
        case .restDays:        week = 2
        case .hydrationDays:   week = 5
        case .habitDays:       week = 5
        }
        guard period == .month else { return week }
        switch aggregation {
        case .hitDays: return min(31, (week * 30 / 7).rounded())
        default:       return (week * 30 / 7 / step(for: .month)).rounded() * step(for: .month)
        }
    }

    var defaultThreshold: Double? {
        switch self {
        case .stepDays:    return 8_000
        case .sleepNights: return 7
        default:           return nil
        }
    }

    /// The most one day can contribute, when there is a hard ceiling. Enables a proven "out of reach".
    var maxPerDay: Double? {
        switch aggregation {
        case .hitDays: return 1
        case .average: return 12
        case .count:   return 3
        case .sum:     return nil
        }
    }

    /// An accepted guideline worth showing beside the personal recommendation, or nil.
    func guideline(for period: PeriodGoal.Period) -> (text: String, source: String)? {
        switch self {
        case .trainingMinutes, .zoneMinutes:
            return period == .week
                ? ("150 to 300 minutes of moderate activity a week", "WHO")
                : ("About 650 to 1,300 minutes of moderate activity a month", "WHO")
        case .sleepNights, .sleepAverage:
            return ("At least 7 hours of sleep a night for adults", "AASM")
        case .workingSets:
            return ("About 10 working sets per muscle group a week", "Schoenfeld 2017")
        case .stepDays:
            return ("Around 7,000 to 10,000 steps a day", "Paluch 2022")
        default:
            return nil
        }
    }
}

/// A weekly or monthly goal. Recurring unless `oneOffPeriodStart` is set: "4 runs a week" holds every
/// week until it is changed, paused or ended.
///
/// A type of its own beside `CoachGoal` on purpose (Q3 of the goals plan): a long-term goal carries a
/// date, a route, a motivation and a safety acknowledgement that a weekly goal does not need, and the
/// coach, the journey and the safety gates all read `CoachGoal`. Keeping the two apart leaves everything
/// that works today untouched; the goal surfaces draw both as one list.
struct PeriodGoal: Codable, Identifiable, Equatable {
    enum Period: String, Codable, CaseIterable, Identifiable {
        case week, month
        var id: String { rawValue }
    }

    enum Status: String, Codable { case active, paused, ended }

    /// A target change, effective from a day key. Periods that started before it keep the old target.
    struct TargetChange: Codable, Equatable {
        let fromDay: String
        let target: Double
    }

    let id: UUID
    var metric: PeriodMetric
    var period: Period
    var target: Double
    /// Steps for a step day, hours for a sleep night.
    var threshold: Double?
    /// Sport names a workout must match (empty = any).
    var sportFilter: [String]
    /// The journal question a habit goal follows, and whether keeping it means answering yes.
    var habitKey: String?
    var habitWantsYes: Bool
    /// Rest weekdays for this goal only. nil = the central rest days from the training settings.
    var restWeekdaysOverride: [Int]?
    /// The long-term goal this one serves, if any.
    var parentGoalId: UUID?
    var status: Status
    /// Set for "only this week/month": the first day of the one period it covers.
    var oneOffPeriodStart: String?
    var pauseIntervals: [CoachGoal.PauseInterval]
    var targetHistory: [TargetChange]
    let createdAt: Date
    var endedAt: Date?
    /// A suggested step-up the wearer already answered for a given period start, so it is asked once.
    var rampAnsweredPeriods: [String]
    /// The weekly target follows the long-term goal it serves (plan Q9): a sum goal sets what each week
    /// needs, from the week's first day on. Setting a target by hand switches it off.
    var followsParent: Bool
    /// Keys a newer build stored on this goal that this build has no field for. Kept verbatim so a save
    /// from this build does not erase them (see `PreservedJSON`).
    var unknownFields: [String: PreservedJSON] = [:]

    init(id: UUID = UUID(), metric: PeriodMetric, period: Period, target: Double, threshold: Double? = nil,
         sportFilter: [String] = [], habitKey: String? = nil, habitWantsYes: Bool = true,
         restWeekdaysOverride: [Int]? = nil, parentGoalId: UUID? = nil, status: Status = .active,
         oneOffPeriodStart: String? = nil, pauseIntervals: [CoachGoal.PauseInterval] = [],
         targetHistory: [TargetChange] = [], createdAt: Date = Date(), endedAt: Date? = nil,
         rampAnsweredPeriods: [String] = [], followsParent: Bool = false) {
        self.id = id
        self.metric = metric
        self.period = period
        self.target = target
        self.threshold = threshold
        self.sportFilter = sportFilter
        self.habitKey = habitKey
        self.habitWantsYes = habitWantsYes
        self.restWeekdaysOverride = restWeekdaysOverride
        self.parentGoalId = parentGoalId
        self.status = status
        self.oneOffPeriodStart = oneOffPeriodStart
        self.pauseIntervals = pauseIntervals
        self.targetHistory = targetHistory
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.rampAnsweredPeriods = rampAnsweredPeriods
        self.followsParent = followsParent
    }

    private enum CodingKeys: String, CodingKey {
        case id, metric, period, target, threshold, sportFilter, habitKey, habitWantsYes
        case restWeekdaysOverride, parentGoalId, status, oneOffPeriodStart, pauseIntervals, targetHistory
        case createdAt, endedAt, rampAnsweredPeriods, followsParent
    }

    // Every field after the first ship decodes with a default, so a stored goal never fails to load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        metric = try c.decodeIfPresent(PeriodMetric.self, forKey: .metric) ?? .workouts
        period = try c.decodeIfPresent(Period.self, forKey: .period) ?? .week
        target = try c.decodeIfPresent(Double.self, forKey: .target) ?? 1
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold)
        sportFilter = try c.decodeIfPresent([String].self, forKey: .sportFilter) ?? []
        habitKey = try c.decodeIfPresent(String.self, forKey: .habitKey)
        habitWantsYes = try c.decodeIfPresent(Bool.self, forKey: .habitWantsYes) ?? true
        restWeekdaysOverride = try c.decodeIfPresent([Int].self, forKey: .restWeekdaysOverride)
        parentGoalId = try c.decodeIfPresent(UUID.self, forKey: .parentGoalId)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .active
        oneOffPeriodStart = try c.decodeIfPresent(String.self, forKey: .oneOffPeriodStart)
        pauseIntervals = try c.decodeIfPresent([CoachGoal.PauseInterval].self, forKey: .pauseIntervals) ?? []
        targetHistory = try c.decodeIfPresent([TargetChange].self, forKey: .targetHistory) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        rampAnsweredPeriods = try c.decodeIfPresent([String].self, forKey: .rampAnsweredPeriods) ?? []
        followsParent = try c.decodeIfPresent(Bool.self, forKey: .followsParent) ?? false
        let all = try decoder.container(keyedBy: AnyCodingKey.self)
        for key in all.allKeys where CodingKeys(stringValue: key.stringValue) == nil {
            if let value = try? all.decode(PreservedJSON.self, forKey: key) { unknownFields[key.stringValue] = value }
        }
    }

    /// Written by hand so the unknown keys go back out beside the known ones.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        func key(_ k: CodingKeys) -> AnyCodingKey { AnyCodingKey(stringValue: k.stringValue) }
        for (name, value) in unknownFields { try c.encode(value, forKey: AnyCodingKey(stringValue: name)) }
        try c.encode(id, forKey: key(.id))
        try c.encode(metric, forKey: key(.metric))
        try c.encode(period, forKey: key(.period))
        try c.encode(target, forKey: key(.target))
        try c.encodeIfPresent(threshold, forKey: key(.threshold))
        try c.encode(sportFilter, forKey: key(.sportFilter))
        try c.encodeIfPresent(habitKey, forKey: key(.habitKey))
        try c.encode(habitWantsYes, forKey: key(.habitWantsYes))
        try c.encodeIfPresent(restWeekdaysOverride, forKey: key(.restWeekdaysOverride))
        try c.encodeIfPresent(parentGoalId, forKey: key(.parentGoalId))
        try c.encode(status, forKey: key(.status))
        try c.encodeIfPresent(oneOffPeriodStart, forKey: key(.oneOffPeriodStart))
        try c.encode(pauseIntervals, forKey: key(.pauseIntervals))
        try c.encode(targetHistory, forKey: key(.targetHistory))
        try c.encode(createdAt, forKey: key(.createdAt))
        try c.encodeIfPresent(endedAt, forKey: key(.endedAt))
        try c.encode(rampAnsweredPeriods, forKey: key(.rampAnsweredPeriods))
        try c.encode(followsParent, forKey: key(.followsParent))
    }

    var isOpen: Bool { status == .active || status == .paused }

    /// The target that applied to the period starting at `periodStart`.
    func target(forPeriodStarting periodStart: String) -> Double {
        // The change log holds the target from each change onwards; the newest change on or before the
        // period's first day wins, later ones belong to later periods. A change made inside the running
        // period applies to it (the wearer meant "from now on").
        let applicable = targetHistory.filter { $0.fromDay <= periodStart }
        if let last = applicable.max(by: { $0.fromDay < $1.fromDay }) { return last.target }
        // No change that early: the oldest recorded target, or the current one.
        return targetHistory.min(by: { $0.fromDay < $1.fromDay })?.target ?? target
    }

    /// The rest weekdays this goal's pace leaves out.
    var effectiveRestWeekdays: [Int] {
        guard metric.usesRestDays else { return [] }
        return restWeekdaysOverride ?? TrainingPreferences.restWeekdays
    }
}

/// A finished period's result, frozen so a later target change or a late import cannot rewrite what
/// already happened.
struct PeriodGoalResult: Codable, Equatable {
    let goalId: UUID
    let periodStart: String
    let target: Double
    let value: Double
    let outcome: PeriodOutcome
    let frozenAt: Date
}

/// Goal preferences that are not goals: limits, order, pins and hints already shown.
enum GoalPrefs {
    static let longTermLimitKey = "goals.limit.longTerm"
    static let periodLimitKey = "goals.limit.period"
    static let pinnedKey = "goals.pinned.longTerm"
    static let introSeenKey = "goals.introSeen"
    static let crowdHintShownKey = "goals.crowdHintShown"
    /// The goals overview's filter chip (`GoalsOverviewFilter`), remembered between visits (plan Q2).
    static let overviewFilterKey = "goals.overview.filter"
    static let attributionAskedKey = "goals.attributionPolicy"
    static let notifyKey = "goals.notify"

    static let defaultLongTermLimit = 5
    static let longTermLimitRange = 1...10
    static let defaultPeriodLimit = 6
    static let periodLimitRange = 1...12
    /// Weekly goals beyond this many get a one-time "this gets hard to follow" hint (Q15).
    static let crowdThreshold = 4

    static var longTermLimit: Int {
        let stored = UserDefaults.standard.integer(forKey: longTermLimitKey)
        return stored == 0 ? defaultLongTermLimit
            : min(longTermLimitRange.upperBound, max(longTermLimitRange.lowerBound, stored))
    }

    static var periodLimit: Int {
        let stored = UserDefaults.standard.integer(forKey: periodLimitKey)
        return stored == 0 ? defaultPeriodLimit
            : min(periodLimitRange.upperBound, max(periodLimitRange.lowerBound, stored))
    }

    static var pinnedLongTermIds: Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    static func setPinned(_ id: UUID, _ pinned: Bool) {
        var ids = pinnedLongTermIds
        if pinned { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: pinnedKey)
    }

    /// Opt-in system notifications per kind (Q4: off by default). The in-app hints run regardless.
    enum NotificationKind: String, CaseIterable, Identifiable {
        case weekStart, midWeek, review
        var id: String { rawValue }
        var label: String {
            switch self {
            case .weekStart: return "Start of the week"
            case .midWeek:   return "Mid-week, when a goal is slipping"
            case .review:    return "Weekly and monthly review"
            }
        }
    }

    static func notifies(_ kind: NotificationKind) -> Bool {
        UserDefaults.standard.bool(forKey: notifyKey + "." + kind.rawValue)
    }

    static func setNotifies(_ kind: NotificationKind, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: notifyKey + "." + kind.rawValue)
    }
}

/// The weekly and monthly goals plus their frozen results, persisted on-device as JSON in UserDefaults
/// (the same posture as `CoachGoalStore`). The array order IS the order the wearer arranged (Q13).
@MainActor
final class PeriodGoalStore: ObservableObject {
    static let shared = PeriodGoalStore()
    static let storageKey = "goals.period.v1"
    static let resultsKey = "goals.periodResults.v1"

    @Published var goals: [PeriodGoal] = [] { didSet { save() } }
    @Published private(set) var results: [PeriodGoalResult] = [] { didSet { saveResults() } }
    /// Goals and results a newer build stored that this one cannot read (a metric it has no case for).
    /// Never shown or evaluated, only written back so they survive this build (`TolerantStoredList`).
    private var foreignGoals: [PreservedJSON] = []
    private var foreignResults: [PreservedJSON] = []

    private let defaults: UserDefaults
    private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(TolerantStoredList<PeriodGoal>.self, from: data) {
            goals = decoded.items
            foreignGoals = decoded.foreign
        }
        if let data = defaults.data(forKey: Self.resultsKey),
           let decoded = try? JSONDecoder().decode(TolerantStoredList<PeriodGoalResult>.self, from: data) {
            results = decoded.items
            foreignResults = decoded.foreign
        }
        isLoading = false
    }

    var openGoals: [PeriodGoal] { goals.filter(\.isOpen) }
    func goal(id: UUID) -> PeriodGoal? { goals.first { $0.id == id } }
    func openGoals(_ period: PeriodGoal.Period) -> [PeriodGoal] { openGoals.filter { $0.period == period } }

    enum AddError: Equatable {
        case limitReached
        /// The same metric is already tracked over the same period (`existingId`).
        case duplicate(existingId: UUID)
    }

    /// Why a goal like `draft` can't be added, or nil. Two goals may share a metric only over different
    /// periods ("runs per week" and "km per month"), or with different sport filters or habits.
    func canAdd(_ draft: PeriodGoal, replacing: UUID? = nil) -> AddError? {
        let others = openGoals.filter { $0.id != replacing }
        if let existing = others.first(where: { sameSlot($0, draft) }) {
            return .duplicate(existingId: existing.id)
        }
        if others.count >= GoalPrefs.periodLimit { return .limitReached }
        return nil
    }

    private func sameSlot(_ a: PeriodGoal, _ b: PeriodGoal) -> Bool {
        a.metric == b.metric && a.period == b.period
            && Set(a.sportFilter.map { $0.lowercased() }) == Set(b.sportFilter.map { $0.lowercased() })
            && a.habitKey == b.habitKey
    }

    /// Adds a new goal at the end of the order, or replaces the one being edited in place.
    func commit(_ draft: PeriodGoal, editingId: UUID? = nil, today: String) {
        if let editingId, let index = goals.firstIndex(where: { $0.id == editingId }) {
            var updated = draft
            let existing = goals[index]
            updated = PeriodGoal(id: existing.id, metric: draft.metric, period: draft.period, target: draft.target,
                                 threshold: draft.threshold, sportFilter: draft.sportFilter,
                                 habitKey: draft.habitKey, habitWantsYes: draft.habitWantsYes,
                                 restWeekdaysOverride: draft.restWeekdaysOverride,
                                 parentGoalId: draft.parentGoalId, status: existing.status,
                                 oneOffPeriodStart: draft.oneOffPeriodStart,
                                 pauseIntervals: existing.pauseIntervals,
                                 targetHistory: existing.targetHistory, createdAt: existing.createdAt,
                                 endedAt: existing.endedAt, rampAnsweredPeriods: existing.rampAnsweredPeriods,
                                 // A target changed by hand in the editor ends following, as `setTarget` does.
                                 followsParent: draft.followsParent && existing.target == draft.target)
            updated.unknownFields = existing.unknownFields
            if existing.target != draft.target {
                updated.targetHistory = Self.recordingChange(existing, to: draft.target, today: today)
            }
            goals[index] = updated
        } else {
            var fresh = draft
            fresh.targetHistory = [.init(fromDay: today, target: draft.target)]
            goals.append(fresh)
        }
    }

    /// Changes only the target, from today on (the detail's stepper and the step-up suggestion). A target
    /// set by hand ends following the long-term goal; `followed` is the store's own weekly update.
    func setTarget(_ id: UUID, _ target: Double, today: String, followed: Bool = false) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        if !followed { goals[index].followsParent = false }
        guard goals[index].target != target else { return }
        goals[index].targetHistory = Self.recordingChange(goals[index], to: target, today: today)
        goals[index].target = target
    }

    private static func recordingChange(_ goal: PeriodGoal, to target: Double, today: String)
        -> [PeriodGoal.TargetChange] {
        var history = goal.targetHistory
        if history.isEmpty {
            // Goals saved before the log existed: anchor their old target at creation.
            history.append(.init(fromDay: Repository.localDayKey(goal.createdAt), target: goal.target))
        }
        history.removeAll { $0.fromDay == today }
        history.append(.init(fromDay: today, target: target))
        return history.sorted { $0.fromDay < $1.fromDay }
    }

    func move(fromOffsets: IndexSet, toOffset: Int, within period: PeriodGoal.Period) {
        var subset = goals.filter { $0.period == period && $0.isOpen }
        subset.move(fromOffsets: fromOffsets, toOffset: toOffset)
        var iterator = subset.makeIterator()
        goals = goals.map { goal in
            guard goal.period == period && goal.isOpen else { return goal }
            return iterator.next() ?? goal
        }
    }

    func pause(_ id: UUID, reason: CoachGoal.PauseReason, on date: Date = Date()) {
        guard let index = goals.firstIndex(where: { $0.id == id }), goals[index].status == .active else { return }
        goals[index].status = .paused
        goals[index].pauseIntervals.append(.init(startedAt: date, endedAt: nil, reason: reason))
    }

    func resume(_ id: UUID, on date: Date = Date()) {
        guard let index = goals.firstIndex(where: { $0.id == id }), goals[index].status == .paused else { return }
        if let open = goals[index].pauseIntervals.lastIndex(where: { $0.endedAt == nil }) {
            goals[index].pauseIntervals[open].endedAt = date
        }
        goals[index].status = .active
    }

    /// Ends a goal; its history stays (the archive).
    func end(_ id: UUID, on date: Date = Date()) {
        guard let index = goals.firstIndex(where: { $0.id == id }), goals[index].isOpen else { return }
        if let open = goals[index].pauseIntervals.lastIndex(where: { $0.endedAt == nil }) {
            goals[index].pauseIntervals[open].endedAt = date
        }
        goals[index].status = .ended
        goals[index].endedAt = date
    }

    func remove(_ id: UUID) {
        goals.removeAll { $0.id == id }
        results.removeAll { $0.goalId == id }
        GoalCountingCorrections.shared.removeGoal(id)
    }

    func markRampAnswered(_ id: UUID, periodStart: String) {
        guard let index = goals.firstIndex(where: { $0.id == id }),
              !goals[index].rampAnsweredPeriods.contains(periodStart) else { return }
        goals[index].rampAnsweredPeriods.append(periodStart)
        if goals[index].rampAnsweredPeriods.count > 60 { goals[index].rampAnsweredPeriods.removeFirst() }
    }

    // MARK: Chain (Q22)

    /// The long-term goal paused: the goals that serve it pause with it, and their weeks are protected.
    func parentPaused(_ parentId: UUID, reason: CoachGoal.PauseReason, on date: Date = Date()) {
        for goal in goals where goal.parentGoalId == parentId && goal.status == .active {
            pause(goal.id, reason: reason, on: date)
        }
    }

    func parentResumed(_ parentId: UUID, on date: Date = Date()) {
        for goal in goals where goal.parentGoalId == parentId && goal.status == .paused {
            resume(goal.id, on: date)
        }
    }

    /// The long-term goal reached or set aside: the serving goals keep running, and the overview asks
    /// once whether to keep them (a habit is often exactly what should outlast the goal).
    func parentClosed(_ parentId: UUID) {
        var pending = Self.pendingChainQuestions
        for goal in goals where goal.parentGoalId == parentId && goal.isOpen { pending.insert(goal.id) }
        Self.pendingChainQuestions = pending
    }

    /// Puts an existing weekly or monthly goal under a long-term goal, which then reads its periods.
    func link(_ id: UUID, to parentId: UUID) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[index].parentGoalId = parentId
    }

    /// The long-term goal deleted: only the link goes.
    func parentRemoved(_ parentId: UUID) {
        for index in goals.indices where goals[index].parentGoalId == parentId {
            goals[index].parentGoalId = nil
        }
    }

    static let chainQuestionKey = "goals.chainQuestions"
    static var pendingChainQuestions: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: chainQuestionKey) ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString).sorted(), forKey: chainQuestionKey) }
    }

    // MARK: Results

    /// Freezes finished periods that are not frozen yet. Returns how many were added.
    @discardableResult
    func freeze(_ new: [PeriodGoalResult]) -> Int {
        let existing = Set(results.map { "\($0.goalId.uuidString):\($0.periodStart)" })
        let additions = new.filter { !existing.contains("\($0.goalId.uuidString):\($0.periodStart)") }
        guard !additions.isEmpty else { return 0 }
        results.append(contentsOf: additions)
        if results.count > 4_000 {
            results = Array(results.sorted { $0.periodStart > $1.periodStart }.prefix(4_000))
        }
        return additions.count
    }

    func results(for goalId: UUID) -> [PeriodGoalResult] {
        results.filter { $0.goalId == goalId }.sorted { $0.periodStart < $1.periodStart }
    }

    private func save() {
        guard !isLoading,
              let data = try? JSONEncoder().encode(TolerantStoredList(items: goals, foreign: foreignGoals)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func saveResults() {
        guard !isLoading,
              let data = try? JSONEncoder().encode(TolerantStoredList(items: results, foreign: foreignResults)) else { return }
        defaults.set(data, forKey: Self.resultsKey)
    }
}

/// The wearer's corrections to what a workout-based goal counted (Q20): a workout that should not
/// count, or one the automatic sport match missed. Keyed by goal and workout key.
@MainActor
final class GoalCountingCorrections: ObservableObject {
    static let shared = GoalCountingCorrections()
    static let storageKey = "goals.countingCorrections.v1"

    struct Correction: Codable, Equatable {
        let goalId: UUID
        let workoutKey: String
        /// true = counts although it did not match; false = does not count although it matched.
        let counts: Bool
    }

    @Published private(set) var corrections: [Correction] = [] { didSet { save() } }
    private let defaults: UserDefaults
    private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Correction].self, from: data) {
            corrections = decoded
        }
        isLoading = false
    }

    func set(goalId: UUID, workoutKey: String, counts: Bool?) {
        corrections.removeAll { $0.goalId == goalId && $0.workoutKey == workoutKey }
        if let counts { corrections.append(.init(goalId: goalId, workoutKey: workoutKey, counts: counts)) }
        if corrections.count > 2_000 { corrections.removeFirst(corrections.count - 2_000) }
    }

    func override(goalId: UUID, workoutKey: String) -> Bool? {
        corrections.last { $0.goalId == goalId && $0.workoutKey == workoutKey }?.counts
    }

    func removeGoal(_ goalId: UUID) {
        corrections.removeAll { $0.goalId == goalId }
    }

    private func save() {
        guard !isLoading, let data = try? JSONEncoder().encode(corrections) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
