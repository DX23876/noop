import Foundation

/// Goals that measure the same thing with different numbers (plan §17g, Q2): two step goals with different
/// thresholds, a weekly workout goal that disagrees with the long-term rate it sits beside, a weekly sum
/// that does not add up to the monthly one. NOOP warns and never blocks; the wearer decides which number
/// counts.
enum GoalConflicts {

    struct Note: Equatable {
        /// The goal the note is shown on: the newer one of the pair.
        let goalId: UUID
        let text: String
    }

    static func notes(actions: [GoalAction], period: [PeriodGoal], longTerm: [CoachGoal], today: String) -> [Note] {
        var notes: [Note] = []
        let daily = actions.filter { $0.isActive && $0.goalIds.isEmpty && !$0.hasEnded(today: today) }
        let open = period.filter(\.isOpen)

        // A daily step or sleep goal against a "days with …" goal using another threshold.
        for action in daily {
            switch action.requirement {
            case .steps(let minimum):
                for goal in open where goal.metric == .stepDays {
                    let threshold = Int((goal.threshold ?? 8_000).rounded())
                    guard threshold != minimum else { continue }
                    notes.append(Note(goalId: newer(action.id, action.createdAt, goal.id, goal.createdAt),
                                      text: String(localized: "Two step goals: \(minimum.formatted()) a day here, days of \(threshold.formatted()) steps there")))
                }
            case .sleep(let hours):
                for goal in open where goal.metric == .sleepNights {
                    let threshold = goal.threshold ?? 7
                    guard abs(threshold - hours) > 0.01 else { continue }
                    let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
                    notes.append(Note(goalId: newer(action.id, action.createdAt, goal.id, goal.createdAt),
                                      text: String(localized: "Two sleep goals: \(hours.formatted(style)) h a night here, nights of \(threshold.formatted(style)) h there")))
                }
            default:
                break
            }
        }

        // A weekly workout goal against a long-term weekly rate, unless it is the one stepping up under it.
        for goal in open where goal.metric == .workouts && goal.period == .week && goal.sportFilter.isEmpty {
            for parent in longTerm where parent.status == .active && parent.kind == .consistency {
                guard goal.parentGoalId != parent.id, let rate = parent.target,
                      Int(rate.rounded()) != Int(goal.target.rounded()) else { continue }
                let name = parent.title.isEmpty ? parent.kind.label.localizedCatalogValue : parent.title
                notes.append(Note(goalId: goal.id,
                                  text: String(localized: "\(name) asks for \(Int(rate.rounded())) a week, this goal for \(Int(goal.target.rounded()))")))
            }
        }

        notes += longTermNotes(longTerm)

        // A weekly sum that does not add up to the monthly goal of the same metric.
        for metric in [PeriodMetric.trainingMinutes, .distance, .zoneMinutes, .workouts] {
            guard let week = open.first(where: { $0.metric == metric && $0.period == .week }),
                  let month = open.first(where: { $0.metric == metric && $0.period == .month }) else { continue }
            let perMonth = week.target * 30.4 / 7
            guard perMonth < month.target * 0.8 || perMonth > month.target * 1.25 else { continue }
            notes.append(Note(goalId: newer(week.id, week.createdAt, month.id, month.createdAt),
                              text: String(localized: "\(GoalFormat.amount(week.target, metric)) a week makes about \(GoalFormat.amount(perMonth, metric)) a month; the monthly goal is \(GoalFormat.amount(month.target, metric))")))
        }
        return notes
    }

    /// Long-term goals the wearer kept side by side that cannot both be served: two weight goals pulling
    /// in opposite directions, or the same template twice with different numbers.
    static func longTermNotes(_ longTerm: [CoachGoal]) -> [Note] {
        var notes: [Note] = []
        let open = longTerm.filter { $0.status == .active || $0.status == .paused }
        for (index, a) in open.enumerated() {
            for b in open[(index + 1)...] {
                let newerId = newer(a.id, a.createdAt, b.id, b.createdAt)
                if a.kind == .weight, b.kind == .weight,
                   let da = direction(a), let db = direction(b), da * db < 0 {
                    notes.append(Note(goalId: newerId,
                                      text: String(localized: "Two weight goals pull in opposite directions")))
                } else if let template = a.templateId, template == b.templateId,
                          sports(a) == sports(b),
                          a.target != b.target {
                    notes.append(Note(goalId: newerId,
                                      text: String(localized: "Two goals of the same kind ask for different numbers")))
                }
            }
        }
        return notes
    }

    /// The sports a catalog goal counts, normalised, so "Running" and "running" are one filter.
    private static func sports(_ goal: CoachGoal) -> [String] {
        (goal.measure?.sportFilter ?? []).map { $0.lowercased() }.sorted()
    }

    /// +1 for a goal that counts up, -1 for one that counts down, nil when the way is not set.
    private static func direction(_ goal: CoachGoal) -> Double? {
        guard let baseline = goal.baseline, let target = goal.target, baseline != target else { return nil }
        return target > baseline ? 1 : -1
    }

    /// What saving `draft` would add, for the setup screens: the notes that exist with it and not without.
    static func notes(adding draft: PeriodGoal, actions: [GoalAction], period: [PeriodGoal],
                      longTerm: [CoachGoal], today: String) -> [String] {
        let others = period.filter { $0.id != draft.id }
        let before = Set(notes(actions: actions, period: others, longTerm: longTerm, today: today).map(\.text))
        return notes(actions: actions, period: others + [draft], longTerm: longTerm, today: today)
            .map(\.text).filter { !before.contains($0) }
    }

    static func notes(adding draft: GoalAction, actions: [GoalAction], period: [PeriodGoal],
                      longTerm: [CoachGoal], today: String) -> [String] {
        let others = actions.filter { $0.id != draft.id }
        let before = Set(notes(actions: others, period: period, longTerm: longTerm, today: today).map(\.text))
        return notes(actions: others + [draft], period: period, longTerm: longTerm, today: today)
            .map(\.text).filter { !before.contains($0) }
    }

    private static func newer(_ a: UUID, _ aDate: Date, _ b: UUID, _ bDate: Date) -> UUID {
        aDate >= bDate ? a : b
    }
}
