import Foundation

/// Proactive coaching (#P10): the coach reacting on its own — a word when you hit a real milestone, or a
/// gentle "let's make this realistic" when you fall behind — instead of only ever answering when asked.
///
/// The detection is PURE and lives here so it can be tested without the network: it reads the structured
/// plan history (not the chat), and only fires on a genuine threshold, never on noise (10.1/10.2/10.3).
/// A generated message costs tokens, so the whole thing is gated behind a user-set level (10.4).

/// How chatty the proactive coach is allowed to be. `off` silences it entirely; `important` limits it to
/// setbacks and big wins (the things worth interrupting for); `normal` also celebrates smaller wins.
enum ProactiveLevel: String, CaseIterable, Identifiable, Codable {
    case off, important, normal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:       return "Off"
        case .important: return "Only important"
        case .normal:    return "Normal"
        }
    }

    var blurb: String {
        switch self {
        case .off:       return "The coach never messages you first."
        case .important: return "Only setbacks and big milestones — the things worth a nudge."
        case .normal:    return "Also small wins and a light weekly review."
        }
    }

    static let storageKey = "ai.proactiveLevel"
}

/// A reason the coach might reach out, detected from the plan history. `seed` is a short factual line the
/// generated message is built around; `important` marks the ones that survive the "only important" level.
struct ProactiveSignal: Equatable {
    enum Category: String, Equatable { case milestone, setback }
    let category: Category
    let important: Bool
    /// A compact, factual seed for the coach message — e.g. "5 sessions completed in a row".
    let seed: String
}

enum ProactiveCoach {

    // MARK: - Thresholds (documented, not magic)

    /// A completion streak this long is a real, celebration-worthy run.
    static let milestoneStreak = 3
    /// A streak this long is a BIG win — surfaces even at the "important only" level.
    static let bigMilestoneStreak = 5
    /// This many completed sessions inside the recent window is a strong week worth a nudge.
    static let strongWeekCompletions = 4
    /// This many skips inside the recent window is a setback worth a realistic-plan conversation.
    static let setbackSkips = 3
    /// The rolling window (days) the week-level counts look back over.
    static let windowDays = 7

    /// A goal whose target date has passed and that nobody has closed out.
    ///
    /// Until now a goal's date simply went by and nothing happened: no verdict, no acknowledgement, and
    /// the goal sat "active" forever against a deadline that was history. That is the one moment a
    /// coach obviously ought to say something — whether it went well or not — and staying silent reads
    /// as not having noticed.
    ///
    /// Pure, so it can be tested without a clock or a network. Returns the goal to review, or nil.
    /// `graceDays` avoids pouncing the morning after: a target date is a target, not a stopwatch.
    static func expiredGoalNeedingReview(_ goals: [CoachGoal],
                                         now: Date = Date(),
                                         graceDays: Int = 1) -> CoachGoal? {
        let cal = Calendar.current
        return goals.first { goal in
            guard goal.status == .active, let target = goal.targetDate else { return false }
            let daysPast = cal.dateComponents([.day],
                                              from: cal.startOfDay(for: target),
                                              to: cal.startOfDay(for: now)).day ?? 0
            return daysPast >= graceDays
        }
    }

    // MARK: - Detection

    /// The single most relevant reason to reach out right now, or nil when nothing crosses a threshold.
    /// Setbacks win over milestones (a body telling you something matters more than a pat on the back),
    /// and the caller's `level` decides whether a non-important signal is allowed through.
    ///
    /// `goals` (#R-multi-goal, renamed from the old singular `goal`) is currently UNUSED in this
    /// function's body — it was reserved plumbing for future goal-aware detection (e.g. a milestone tied
    /// to a specific goal's `Kind`) that was never implemented. Kept as a parameter (renamed for
    /// signature consistency with the rest of the multi-goal store) rather than silently dropped, so a
    /// future goal-aware detector has it ready without another signature change — implementing that
    /// detection itself is a separate, larger feature, out of scope here.
    static func detect(proposals: [PlanProposal], goals: [CoachGoal],
                       level: ProactiveLevel, now: Date = Date()) -> ProactiveSignal? {
        guard level != .off else { return nil }

        if let setback = detectSetback(proposals: proposals, now: now) {
            return setback   // setbacks are always important, so they pass every non-off level
        }

        if let milestone = detectMilestone(proposals: proposals, now: now) {
            if level == .important && !milestone.important { return nil }
            return milestone
        }

        return nil
    }

    // MARK: - Setback (10.3)

    static func detectSetback(proposals: [PlanProposal], now: Date) -> ProactiveSignal? {
        // A run of declines is the filter-bubble signal (already the store's floor): the user keeps
        // saying "not today", and the coach should ask what's actually wrong rather than shrink forever.
        let declines = declineStreak(proposals)
        if declines >= CoachPlanStore.declineStreakFloor {
            return ProactiveSignal(category: .setback, important: true,
                                   seed: "\(declines) suggested sessions declined in a row")
        }
        // Repeated skips inside the window: committed, then didn't happen. That's falling behind.
        let skips = countStatuses(proposals, in: [.skipped], within: windowDays, now: now)
        if skips >= setbackSkips {
            return ProactiveSignal(category: .setback, important: true,
                                   seed: "\(skips) committed sessions missed in the last \(windowDays) days")
        }
        return nil
    }

    // MARK: - Milestone (10.2)

    static func detectMilestone(proposals: [PlanProposal], now: Date) -> ProactiveSignal? {
        let streak = completionStreak(proposals)
        if streak >= bigMilestoneStreak {
            return ProactiveSignal(category: .milestone, important: true,
                                   seed: "\(streak) sessions completed in a row")
        }
        if streak >= milestoneStreak {
            return ProactiveSignal(category: .milestone, important: false,
                                   seed: "\(streak) sessions completed in a row")
        }
        let completions = countStatuses(proposals, in: [.completed], within: windowDays, now: now)
        if completions >= strongWeekCompletions {
            return ProactiveSignal(category: .milestone, important: false,
                                   seed: "\(completions) sessions completed in the last \(windowDays) days")
        }
        return nil
    }

    // MARK: - Pure counting helpers

    /// Consecutive `.completed` sessions among the DECIDED proposals, most-recent decision first — the
    /// run breaks at the first decided-but-not-completed session (a skip, decline, or still-open plan).
    static func completionStreak(_ proposals: [PlanProposal]) -> Int {
        var streak = 0
        for p in decidedNewestFirst(proposals) {
            if p.status == .completed { streak += 1 } else { break }
        }
        return streak
    }

    /// Consecutive `.declined` among decided proposals, newest first (mirrors `CoachPlanStore.declineStreak`
    /// but as a pure function over any proposal list, so the detector is testable in isolation).
    static func declineStreak(_ proposals: [PlanProposal]) -> Int {
        var streak = 0
        for p in decidedNewestFirst(proposals) {
            if p.status == .declined { streak += 1 } else { break }
        }
        return streak
    }

    /// Count proposals whose status is in `statuses` and whose decision landed inside the last `within`
    /// days. Uses `decidedAt` (falling back to `createdAt`) so the window tracks WHEN it happened.
    static func countStatuses(_ proposals: [PlanProposal], in statuses: Set<PlanProposal.Status>,
                              within days: Int, now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return proposals.filter {
            statuses.contains($0.status) && ($0.decidedAt ?? $0.createdAt) >= cutoff
        }.count
    }

    private static func decidedNewestFirst(_ proposals: [PlanProposal]) -> [PlanProposal] {
        proposals.filter { $0.status.isDecided }
            .sorted { ($0.decidedAt ?? $0.createdAt) > ($1.decidedAt ?? $1.createdAt) }
    }
}
