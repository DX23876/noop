import Foundation
import StrandAnalytics
import WhoopStore

/// Keeps period goals useful over time (Q16) and speaks about them in the app's existing channels:
/// one Momentum entry at a time, and optional system notifications the wearer turned on.
///
/// Frequency is bounded by WHEN a hint may appear, not by remembering that it did: a review on the first
/// two days of a period, a first-week check on the third day after setup, upkeep on the first two days
/// of a month. Nothing here changes a goal; every suggestion waits for a tap.
enum GoalMaintenance {

    static let adjustAfter = PeriodGoalMaintenance.adjustAfter
    static let habitAfterWeeks = PeriodGoalMaintenance.habitAfterWeeks
    static let struggleAfterWeeks = PeriodGoalMaintenance.struggleAfterWeeks
    typealias Upkeep = PeriodGoalMaintenance.Upkeep

    static func adjustment(for snapshot: PeriodGoalSnapshot) -> Double? { PeriodGoalMaintenance.adjustment(for: snapshot) }
    static func upkeep(for snapshot: PeriodGoalSnapshot) -> Upkeep? { PeriodGoalMaintenance.upkeep(for: snapshot) }

    // MARK: - Momentum

    /// At most one goal entry for Today's Momentum card, the most useful one right now.
    @MainActor
    static func momentumCheckIn(snapshots: [PeriodGoalSnapshot], recentDays: [DailyMetric],
                                now: Date = Date()) -> MomentumMessage? {
        let open = snapshots.filter { $0.goal.status == .active }
        let calendar = TrainingPreferences.weekCalendar
        let today = PeriodGoalTracker.dayKey(now, calendar: calendar)

        // 1. A finished week to look back on, on the first two days of the new one.
        let weekGoals = open.filter { $0.goal.period == .week && !$0.history.isEmpty }
        if let first = weekGoals.first, first.todayIndex <= 1 {
            let last = weekGoals.compactMap(\.history.last)
            let reached = last.filter { $0.outcome == .achieved }.count
            return MomentumMessage(
                kind: .goalCheckIn, tone: reached == last.count ? .positive : .neutral,
                headline: String(localized: "Last week: \(reached) of \(last.count) goals reached"),
                detail: adjustmentSentence(weekGoals) ?? String(localized: "A new week starts. Your goals carry on."),
                action: MomentumAction(title: String(localized: "Review"), destination: .goalJourney))
        }

        // 2. The first week of a new goal: a quiet word on day three (the first week predicts most).
        if let fresh = open.first(where: { daysSince($0.goal.createdAt, now: now, calendar: calendar) == 3 }) {
            return MomentumMessage(
                kind: .goalCheckIn, tone: .neutral,
                headline: String(localized: "Three days into \(GoalFormat.shortName(fresh.goal))"),
                detail: GoalFormat.remainingLine(fresh),
                progress: MomentumProgress(fraction: min(1, fresh.result.fraction), label: GoalFormat.progress(fresh)),
                action: MomentumAction(title: String(localized: "View goal"), destination: .goalJourney))
        }

        // 3. Upkeep, on the first two days of a month.
        if let day = Int(today.suffix(2)), day <= 2,
           let (snapshot, upkeep) = open.lazy.compactMap({ s in upkeep(for: s).map { (s, $0) } }).first {
            return MomentumMessage(
                kind: .goalCheckIn, tone: .neutral,
                headline: upkeep == .habit
                    ? String(localized: "\(GoalFormat.shortName(snapshot.goal)) has become a habit")
                    : String(localized: "\(GoalFormat.shortName(snapshot.goal)) keeps slipping"),
                detail: upkeep == .habit
                    ? String(localized: "Reached \(habitAfterWeeks) weeks in a row. Raise it, or end it and keep the habit?")
                    : String(localized: "Missed \(struggleAfterWeeks) weeks in a row. Lower it or pause it?"),
                action: MomentumAction(title: String(localized: "Adjust"), destination: .goalJourney))
        }

        // 4. A goal the data suggests, at the start of a week, when nothing similar exists.
        if open.isEmpty || calendar.component(.weekday, from: now) == calendar.firstWeekday {
            let hasSleepGoal = open.contains { $0.goal.metric == .sleepNights || $0.goal.metric == .sleepAverage }
            let nights = recentDays.suffix(21).compactMap(\.totalSleepMin).map { $0 / 60 }
            if !hasSleepGoal, nights.count >= 14 {
                let mean = nights.reduce(0, +) / Double(nights.count)
                if mean < 7 {
                    return MomentumMessage(
                        kind: .goalCheckIn, tone: .neutral,
                        headline: String(localized: "A sleep goal?"),
                        detail: String(localized: "You have slept \(mean.formatted(.number.precision(.fractionLength(1)))) h a night on average for three weeks. Seven or more is recommended."),
                        action: MomentumAction(title: String(localized: "Set one"), destination: .goalJourney))
                }
            }
        }
        return nil
    }

    private static func adjustmentSentence(_ snapshots: [PeriodGoalSnapshot]) -> String? {
        for snapshot in snapshots {
            guard let next = adjustment(for: snapshot) else { continue }
            return next > snapshot.goal.target
                ? String(localized: "\(GoalFormat.shortName(snapshot.goal)): three weeks reached. Try \(GoalFormat.amount(next, snapshot.goal.metric))?")
                : String(localized: "\(GoalFormat.shortName(snapshot.goal)): three weeks short. Try \(GoalFormat.amount(next, snapshot.goal.metric))?")
        }
        return nil
    }

    private static func daysSince(_ date: Date, now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    }

    /// The weekly goal that should drive Momentum's "sessions short of your week" entry: the first open
    /// count goal that is slipping, with its numbers.
    @MainActor
    static func weeklyShortfall(_ snapshots: [PeriodGoalSnapshot]) -> (planned: Int, done: Int, daysLeft: Int)? {
        PeriodGoalMaintenance.weeklyShortfall(snapshots)
    }
}
