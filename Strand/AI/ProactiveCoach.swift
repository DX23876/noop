import Foundation
import WhoopStore

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

/// A reason the coach might reach out, detected from the plan history OR the raw biometrics. `seed` is a
/// short factual line the generated message is built around; `important` marks the ones that survive the
/// "only important" level.
struct ProactiveSignal: Equatable {
    /// `bodyConcern`/`bodyPositive` are split (not one `bodySignal` case) because both the instruction
    /// template (`AICoachEngine.proactiveNudgeInstruction`) and the nudge-message prefix
    /// (`AICoachEngine.runProactiveNudgeIfNeeded`) need to know the sentiment, not just "this came from
    /// biometrics" — a positive HRV uptrend reads nothing like a concerning one.
    enum Category: String, Equatable { case milestone, setback, bodyConcern, bodyPositive, goalDeadline }
    let category: Category
    let important: Bool
    /// A compact, factual seed for the coach message — e.g. "5 sessions completed in a row".
    let seed: String
    /// The goal this signal is about — set only for `.goalDeadline`, so the caller can stamp a per-goal
    /// repeat-guard instead of the coarser once-per-day one. Nil for every other category.
    let goalId: UUID?

    init(category: Category, important: Bool, seed: String, goalId: UUID? = nil) {
        self.category = category
        self.important = important
        self.seed = seed
        self.goalId = goalId
    }
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

    // MARK: - Biometric trend thresholds
    //
    // % moves off the wearer's OWN recent baseline, not a fixed absolute number — HRV magnitude varies
    // hugely person to person, so a flat "-15ms" is meaningless for someone whose baseline is 30ms and
    // trivial for someone at 120ms. `trailingNights` is the recent window a trend is measured over;
    // `baselineNights` is the immediately-preceding window it's compared against (both counted in VALID
    // nights, i.e. skipping days with no reading, not calendar days).

    /// Recent window a biometric trend is measured over.
    static let trailingNights = 5
    /// Shorter recent window for signals that move faster / matter sooner (recovery, sleep).
    static let trailingNightsShort = 3
    /// The preceding window a trend is compared against.
    static let baselineNights = 14
    /// HRV trailing-mean ≤ baseline-mean × this ratio → a concerning downtrend (≥15% drop).
    static let hrvDownRatio = 0.85
    /// HRV trailing-mean ≥ baseline-mean × this ratio → a positive uptrend (≥15% rise).
    static let hrvUpRatio = 1.15
    /// Resting HR trailing-mean ≥ baseline-mean × this ratio → a concerning uptrend. Smaller move than
    /// HRV's because resting HR is the steadier of the two signals.
    static let rhrUpRatio = 1.08
    /// Sleep-minutes trailing-mean ≤ baseline-mean × this ratio → a concerning downtrend.
    static let sleepDownRatio = 0.85
    /// Recovery score (0–100) below this on EVERY night of the short trailing window → sustained poor
    /// recovery, not one rough night.
    static let recoveryFloor = 33.0

    /// Whole CALENDAR days between an active goal's target date and `now` (positive once the date is
    /// past), or nil for a goal with no target date. Day-based, not `weeksRemaining()`'s continuous
    /// `timeIntervalSince` — so a goal that passed its target 30 minutes ago doesn't already read as
    /// "1 day overdue", and the UI's expired-goal card (`CoachGoalJourneyView.expiredGoals`) and the
    /// chat's `expiredGoalNeedingReview` agree on exactly when a goal counts as overdue.
    static func daysPastTarget(_ goal: CoachGoal, now: Date = Date()) -> Int? {
        guard let target = goal.targetDate else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day],
                                  from: cal.startOfDay(for: target),
                                  to: cal.startOfDay(for: now)).day
    }

    /// A goal whose target date has passed and that nobody has closed out.
    ///
    /// Until now a goal's date simply went by and nothing happened: no verdict, no acknowledgement, and
    /// the goal sat "active" forever against a deadline that was history. That is the one moment a
    /// coach obviously ought to say something — whether it went well or not — and staying silent reads
    /// as not having noticed.
    ///
    /// Pure, so it can be tested without a clock or a network. Returns the MOST overdue goal to review
    /// (ties broken by array order), or nil — deterministic, so which goal gets reviewed first never
    /// depends on incidental store ordering. `graceDays` avoids pouncing the morning after: a target date
    /// is a target, not a stopwatch.
    static func expiredGoalNeedingReview(_ goals: [CoachGoal],
                                         now: Date = Date(),
                                         graceDays: Int = 1) -> CoachGoal? {
        let overdue = goals.enumerated().compactMap { idx, goal -> (Int, Int, CoachGoal)? in
            guard goal.status == .active, let daysPast = daysPastTarget(goal, now: now) else { return nil }
            guard daysPast >= graceDays else { return nil }
            return (daysPast, idx, goal)
        }
        return overdue.max { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 > b.1 }?.2
    }

    /// An active goal whose target date is 0-14 days away — the forward-looking counterpart to
    /// `expiredGoalNeedingReview` (which only ever looks BACK at a date already past). `important` marks
    /// the ≤7-day band (worth interrupting for); 8-14 days is "nice to know", filtered out at the
    /// `.important` level same as a small milestone. The nearest deadline wins when several goals qualify,
    /// ties broken by array order — deterministic, not dependent on store ordering.
    ///
    /// `goal.phase(from:)` (only non-nil for `.run`/`.strength`) is folded into the seed when available,
    /// since it's exactly the kind of context a deadline nudge should carry ("taper phase" reads very
    /// differently from "base phase" 5 days out).
    static func detectGoalDeadline(goals: [CoachGoal], now: Date = Date()) -> ProactiveSignal? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let candidates = goals.compactMap { goal -> (goal: CoachGoal, daysLeft: Int)? in
            guard goal.status == .active, let target = goal.targetDate else { return nil }
            let daysLeft = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: target)).day ?? -1
            guard (0...14).contains(daysLeft) else { return nil }
            return (goal, daysLeft)
        }
        guard let nearest = candidates.min(by: { $0.daysLeft < $1.daysLeft }) else { return nil }

        let dayWord = nearest.daysLeft == 1 ? "day" : "days"
        var seed = "\(nearest.goal.title) target date is in \(nearest.daysLeft) \(dayWord)"
        if let phase = nearest.goal.phase(from: now) {
            seed += " (\(phase) phase)"
        }
        return ProactiveSignal(category: .goalDeadline, important: nearest.daysLeft <= 7,
                               seed: seed, goalId: nearest.goal.id)
    }

    // MARK: - Detection

    /// The single most relevant reason to reach out right now, or nil when nothing crosses a threshold.
    /// Setbacks win over milestones (a body telling you something matters more than a pat on the back),
    /// and the caller's `level` decides whether a non-important signal is allowed through.
    ///
    /// `goals` feeds `detectGoalDeadline` — a forward-looking deadline nudge, slotted into the priority
    /// chain by its own `important` split: a deadline ≤7 days out ranks with a concerning biometric signal
    /// (worth interrupting for), while 8-14 days out ranks with a small milestone (nice to know, filtered
    /// at `.important`).
    ///
    /// `days` feeds the biometric trend check (HRV/RHR/recovery/sleep) — a concerning body signal outranks
    /// a plan setback (the body telling you something outranks an adherence miss), and a positive HRV
    /// uptrend is checked after a plan milestone (a secondary, quieter kind of good news).
    static func detect(proposals: [PlanProposal], goals: [CoachGoal], days: [DailyMetric],
                       level: ProactiveLevel, now: Date = Date()) -> ProactiveSignal? {
        guard level != .off else { return nil }

        let biometric = detectBiometricSignal(days: days, now: now)
        if let biometric, biometric.category == .bodyConcern {
            return biometric   // always important, passes every non-off level
        }

        let goalDeadline = detectGoalDeadline(goals: goals, now: now)
        if let goalDeadline, goalDeadline.important {
            return goalDeadline   // ≤7 days out — always important, passes every non-off level
        }

        if let setback = detectSetback(proposals: proposals, now: now) {
            return setback   // setbacks are always important, so they pass every non-off level
        }

        if let goalDeadline {
            // Only the 8-14 day (non-important) band reaches here — the ≤7 day band already returned above.
            if level == .important { return nil }
            return goalDeadline
        }

        if let milestone = detectMilestone(proposals: proposals, now: now) {
            if level == .important && !milestone.important { return nil }
            return milestone
        }

        if let biometric, biometric.category == .bodyPositive {
            if level == .important && !biometric.important { return nil }
            return biometric
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

    // MARK: - Biometric trend (HRV / RHR / recovery / sleep)

    /// The single most relevant biometric trend, checked in priority order — a concerning signal always
    /// wins over a positive one (a body asking for rest matters more than one saying "keep going"), and
    /// among concerning signals HRV leads (the earliest, most sensitive of the four to change).
    static func detectBiometricSignal(days: [DailyMetric], now: Date) -> ProactiveSignal? {
        if let hrvDown = trendSignal(days: days, now: now, field: \.avgHrv, nights: trailingNights,
                                     ratio: hrvDownRatio, direction: .down,
                                     seedFormat: { "HRV down about \(percentText($0)) over the last \(trailingNights) nights" }) {
            return ProactiveSignal(category: .bodyConcern, important: true, seed: hrvDown)
        }
        if let recoveryLow = detectSustainedLowRecovery(days: days, now: now) {
            return ProactiveSignal(category: .bodyConcern, important: true, seed: recoveryLow)
        }
        if let rhrUp = trendSignal(days: days, now: now, field: { $0.restingHr.map(Double.init) },
                                   nights: trailingNights, ratio: rhrUpRatio, direction: .up,
                                   seedFormat: { "Resting heart rate up about \(percentText($0)) over the last \(trailingNights) nights" }) {
            return ProactiveSignal(category: .bodyConcern, important: true, seed: rhrUp)
        }
        if let sleepDown = trendSignal(days: days, now: now, field: \.totalSleepMin, nights: trailingNightsShort,
                                       ratio: sleepDownRatio, direction: .down,
                                       seedFormat: { "Sleep duration down about \(percentText($0)) over the last \(trailingNightsShort) nights" }) {
            return ProactiveSignal(category: .bodyConcern, important: false, seed: sleepDown)
        }
        if let hrvUp = trendSignal(days: days, now: now, field: \.avgHrv, nights: trailingNights,
                                   ratio: hrvUpRatio, direction: .up,
                                   seedFormat: { "HRV up about \(percentText($0)) over the last \(trailingNights) nights" }) {
            return ProactiveSignal(category: .bodyPositive, important: false, seed: hrvUp)
        }
        return nil
    }

    private enum TrendDirection { case up, down }

    /// A plain "yyyy-MM-dd" for `date`, matching `DailyMetric.day`'s format. Deliberately NOT
    /// `Repository.logicalDayKey` (which is `@MainActor`-isolated and rollover-hour-aware) — this whole
    /// file stays plain/nonisolated like `detectSetback`/`detectMilestone` so it's testable without the
    /// network or a store singleton, and the future-day guard below only needs a coarse "is this date-only
    /// string plausibly in the future" check, not the exact logical-day boundary.
    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// A % move off a personal baseline: the mean of the trailing `nights` valid readings against the
    /// mean of the `baselineNights` valid readings immediately before that window. Nights with no reading
    /// are skipped (never treated as zero), so a gap in strap wear can't fake a trend. Returns a seed
    /// string via `seedFormat` (the actual % move, one decimal) when the ratio crosses the threshold in
    /// `direction`, else nil. Needs the FULL `trailingNights + baselineNights` valid readings to fire —
    /// half a baseline is not a baseline.
    private static func trendSignal(days: [DailyMetric], now: Date, field: (DailyMetric) -> Double?,
                                    nights: Int, ratio: Double, direction: TrendDirection,
                                    seedFormat: (Double) -> String) -> String? {
        // Defensive future-day guard (mirrors TodayView.lastScoredRecoveryDay #547): a stray
        // future-dated row from a bad-clock strap must never anchor "recent," belt-and-suspenders on
        // top of the ingest gate.
        let todayKey = dayKey(now)
        let ordered = days.filter { $0.day <= todayKey }.sorted { $0.day < $1.day }
        let valid = ordered.compactMap(field)
        guard valid.count >= nights + baselineNights else { return nil }
        let trailing = Array(valid.suffix(nights))
        let baseline = Array(valid.suffix(nights + baselineNights).prefix(baselineNights))
        let trailingMean = trailing.reduce(0, +) / Double(trailing.count)
        let baselineMean = baseline.reduce(0, +) / Double(baseline.count)
        guard baselineMean > 0 else { return nil }
        let moved: Bool
        switch direction {
        case .down: moved = trailingMean <= baselineMean * ratio
        case .up:   moved = trailingMean >= baselineMean * ratio
        }
        guard moved else { return nil }
        let percentMove = abs(trailingMean - baselineMean) / baselineMean * 100
        return seedFormat(percentMove)
    }

    private static func percentText(_ percent: Double) -> String { String(format: "%.0f%%", percent) }

    /// Recovery (0–100) below `recoveryFloor` on EVERY one of the trailing `trailingNightsShort` valid
    /// nights — sustained, not one rough night. Unlike `trendSignal` this isn't a move off baseline: a
    /// wearer whose recovery always runs low has nothing to compare against, and a flat "stayed under 33"
    /// is the honest signal regardless of their personal norm.
    private static func detectSustainedLowRecovery(days: [DailyMetric], now: Date) -> String? {
        let todayKey = dayKey(now)
        let ordered = days.filter { $0.day <= todayKey }.sorted { $0.day < $1.day }
        let valid = ordered.compactMap(\.recovery)
        guard valid.count >= trailingNightsShort else { return nil }
        let trailing = valid.suffix(trailingNightsShort)
        guard trailing.allSatisfy({ $0 < recoveryFloor }) else { return nil }
        return "Recovery under \(Int(recoveryFloor))% for \(trailingNightsShort) nights running"
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
