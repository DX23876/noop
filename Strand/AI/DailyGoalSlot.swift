import Foundation

/// The measured daily goals the goals page sets on their own (steps, active calories, sleep): their values, how a
/// value becomes a requirement, which stored goal fills the slot, and how the editor saves and turns one off.
/// Shared with the Android core (parity plan 2.3), so both editors store the same `GoalAction`.
enum DailyGoalSlot: String, CaseIterable, Identifiable {
    case steps, activeCalories, sleep

    /// How long a daily goal runs.
    enum Runs: String, CaseIterable, Identifiable {
        case ongoing, untilDate, todayOnly
        var id: String { rawValue }
    }

    var id: String { rawValue }

    var metric: PeriodMetric {
        switch self {
        case .steps: return .stepDays
        case .activeCalories: return .activeEnergy
        case .sleep: return .sleepNights
        }
    }

    var values: [Double] {
        switch self {
        case .steps: return stride(from: 2_000.0, through: 40_000, by: 500).map { $0 }
        case .activeCalories: return stride(from: 100.0, through: 2_000, by: 50).map { $0 }
        case .sleep: return stride(from: 5.0, through: 10, by: 0.25).map { $0 }
        }
    }

    var defaultValue: Double {
        switch self {
        case .steps: return 10_000
        case .activeCalories: return 500
        case .sleep: return 7.5
        }
    }

    func requirement(_ value: Double) -> GoalAction.Requirement {
        switch self {
        case .steps: return .steps(minimum: Int(value))
        case .activeCalories: return .activeCalories(minimum: Int(value))
        case .sleep: return .sleep(minimumHours: value)
        }
    }

    func value(of requirement: GoalAction.Requirement) -> Double? {
        switch (self, requirement) {
        case (.steps, .steps(let m)): return Double(m)
        case (.activeCalories, .activeCalories(let m)): return Double(m)
        case (.sleep, .sleep(let h)): return h
        default: return nil
        }
    }

    /// The standalone daily goal filling this slot, if one is set and running.
    func current(in actions: [GoalAction], today: String) -> GoalAction? {
        actions.first { $0.isActive && $0.goalIds.isEmpty && !$0.hasEnded(today: today)
            && value(of: $0.requirement) != nil }
    }

    /// The title a new goal in this slot is stored with.
    var defaultTitle: String {
        switch self {
        case .steps: return String(localized: "Daily steps")
        case .activeCalories: return String(localized: "Active calories")
        case .sleep: return String(localized: "Sleep")
        }
    }

    /// The nearest offered value, for a stored goal whose value the wheel does not list.
    func nearest(_ value: Double) -> Double {
        values.contains(value) ? value : (values.min { abs($0 - value) < abs($1 - value) } ?? defaultValue)
    }

    /// Saves the slot's goal as the editor's Done does: a new goal, or the running one changed in place.
    /// `weekdays` are calendar weekdays (1 Sunday ... 7 Saturday); `endsOn` is the last day for `.untilDate`.
    @MainActor
    func save(in store: GoalActionStore, value: Double, runs: Runs, endsOn: String?, weekdays: Set<Int>,
              showsAsRing: Bool, today: String, now: Date = Date()) {
        let existing = current(in: store.actions, today: today)
        let lastDay: String?
        switch runs {
        case .ongoing: lastDay = nil
        case .untilDate: lastDay = endsOn
        case .todayOnly: lastDay = today
        }
        let schedule: GoalAction.Schedule = (runs == .todayOnly || weekdays.count == 7) ? .daily : .weekdays(weekdays.sorted())
        store.upsert(GoalAction(id: existing?.id ?? UUID(), title: existing?.title ?? defaultTitle,
                                requirement: requirement(value), schedule: schedule, goalIds: [],
                                createdAt: existing?.createdAt ?? now, endsOn: lastDay,
                                showsAsRing: showsAsRing ? existing?.showsAsRing.flatMap { $0 ? true : nil } : false))
    }

    /// Off keeps the goal and its history (it moves to the ended goals); it can be set again any time.
    @MainActor
    func turnOff(in store: GoalActionStore, today: String, yesterday: String) {
        guard var action = current(in: store.actions, today: today) else { return }
        action.endsOn = yesterday
        store.upsert(action)
    }
}
