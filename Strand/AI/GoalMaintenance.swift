import Foundation
import StrandAnalytics
import WhoopStore
import StrandDesign
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Keeps period goals useful over time (Q16) and speaks about them in the app's existing channels:
/// one Momentum entry at a time, and optional system notifications the wearer turned on.
///
/// Frequency is bounded by WHEN a hint may appear, not by remembering that it did: a review on the first
/// two days of a period, a first-week check on the third day after setup, upkeep on the first two days
/// of a month. Nothing here changes a goal; every suggestion waits for a tap.
enum GoalMaintenance {

    /// Periods in a row before a step up or down is offered.
    static let adjustAfter = 3
    /// Upkeep: weeks always reached before "raise it or keep it as a habit", weeks missed before
    /// "lower it or pause it".
    static let habitAfterWeeks = 8
    static let struggleAfterWeeks = 4

    // MARK: - Adjustments

    /// The next period's suggested target, or nil: one step up after three reached periods, one step down
    /// after three missed ones. Recurring active goals only.
    static func adjustment(for snapshot: PeriodGoalSnapshot) -> Double? {
        let goal = snapshot.goal
        guard goal.status == .active, goal.oneOffPeriodStart == nil else { return nil }
        let recent = snapshot.history.suffix(adjustAfter)
        guard recent.count == adjustAfter else { return nil }
        let step = goal.metric.step(for: goal.period)
        let range = goal.metric.range(for: goal.period)
        if recent.allSatisfy({ $0.outcome == .achieved }) {
            let up = min(range.upperBound, goal.target + step)
            return up > goal.target ? up : nil
        }
        if recent.allSatisfy({ $0.outcome == .missed }) {
            let down = max(range.lowerBound, goal.target - step)
            return down < goal.target ? down : nil
        }
        return nil
    }

    enum Upkeep: Equatable { case habit, struggling }

    static func upkeep(for snapshot: PeriodGoalSnapshot) -> Upkeep? {
        guard snapshot.goal.status == .active, snapshot.goal.period == .week else { return nil }
        let outcomes = snapshot.history.map(\.outcome).filter { $0 != .protected && $0 != .noData }
        if outcomes.count >= habitAfterWeeks, outcomes.suffix(habitAfterWeeks).allSatisfy({ $0 == .achieved }) {
            return .habit
        }
        if outcomes.count >= struggleAfterWeeks, outcomes.suffix(struggleAfterWeeks).allSatisfy({ $0 == .missed }) {
            return .struggling
        }
        return nil
    }

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
        guard let s = snapshots.first(where: {
            $0.goal.status == .active && $0.goal.period == .week && $0.goal.metric == .workouts
                && GoalStatusStyle.needsAttention($0.state)
        }) else { return nil }
        return (Int(s.result.target.rounded()), Int(s.result.current.rounded()), max(1, s.daysLeft))
    }
}

/// Optional system notifications for goals (off by default, Q4). Scheduled one-shot on each tracking
/// refresh from the latest state, through the same `UNCalendarNotificationTrigger` mechanism as the plan
/// reminders, and never inside the wearer's quiet hours.
enum GoalNotifier {
    static let weekStartId = "goals.notify.weekStart"
    static let midWeekId = "goals.notify.midWeek"
    static let reviewId = "goals.notify.review"

    static func requestAuthorization() {
        #if canImport(UserNotifications)
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        #endif
    }

    @MainActor
    static func reschedule(_ snapshots: [PeriodGoalSnapshot], now: Date = Date()) {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [weekStartId, midWeekId, reviewId])
        let week = snapshots.filter { $0.goal.status == .active && $0.goal.period == .week }
        guard !week.isEmpty, UserDefaults.standard.object(forKey: "notif.masterEnabled") as? Bool ?? true else { return }
        let calendar = TrainingPreferences.weekCalendar
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return }

        if GoalPrefs.notifies(.weekStart),
           let next = calendar.date(byAdding: .day, value: 7, to: interval.start).flatMap({ at($0, hour: 8, calendar) }) {
            schedule(weekStartId, title: String(localized: "A new week"),
                     body: week.map { GoalFormat.title($0.goal) }.prefix(3).joined(separator: " · "), at: next)
        }
        if GoalPrefs.notifies(.midWeek),
           let slipping = week.first(where: { $0.state == .close }),
           let thursday = calendar.date(byAdding: .day, value: 3, to: interval.start).flatMap({ at($0, hour: 18, calendar) }),
           thursday > now {
            schedule(midWeekId, title: GoalFormat.shortName(slipping.goal), body: GoalFormat.remainingLine(slipping),
                     at: thursday)
        }
        if GoalPrefs.notifies(.review),
           let lastDay = calendar.date(byAdding: .day, value: 6, to: interval.start).flatMap({ at($0, hour: 19, calendar) }),
           lastDay > now {
            schedule(reviewId, title: String(localized: "Your week"),
                     body: String(localized: "See how your goals went and set up the next week."), at: lastDay)
        }
        #endif
    }

    private static func at(_ day: Date, hour: Int, _ calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    /// True when `date` falls inside the wearer's quiet hours (the shared notification settings).
    static func isQuiet(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: "notif.quietHoursEnabled") else { return false }
        let start = d.object(forKey: "notif.quietStartMinutes") as? Int ?? 22 * 60
        let end = d.object(forKey: "notif.quietEndMinutes") as? Int ?? 7 * 60
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return start <= end ? (minutes >= start && minutes < end) : (minutes >= start || minutes < end)
    }

    #if canImport(UserNotifications)
    private static func schedule(_ id: String, title: String, body: String, at date: Date) {
        guard !isQuiet(date), !body.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "goals"
        let comps = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
    #endif
}

/// Short goal sentences for the app's EXISTING reminders (the move reminder, the wind-down nudge, a
/// planned session's reminder), so goals speak through them instead of adding notifications (§8a.3).
///
/// Written to UserDefaults on every tracking refresh and read from wherever a reminder is composed,
/// which is not always the main actor.
enum GoalReminderLines {
    private static let stepsKey = "goals.line.steps"
    private static let sleepKey = "goals.line.sleepGoal"
    private static let trainingKey = "goals.line.training"

    /// "2,300 steps to your daily goal." while today's step goal is open.
    static var steps: String? { UserDefaults.standard.string(forKey: stepsKey) }
    static var hasSleepGoal: Bool { UserDefaults.standard.bool(forKey: sleepKey) }

    /// "Counts toward Runs (2/4)." for a planned session of `sport`, when a weekly goal counts it.
    static func training(for sport: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: trainingKey),
              let lines = try? JSONDecoder().decode([TrainingLine].self, from: data) else { return nil }
        return lines.first { GoalActionEvaluator.matches(sport, any: $0.sports) }?.text
    }

    private struct TrainingLine: Codable { let sports: [String]; let text: String }

    @MainActor
    static func update(periodSnapshots: [PeriodGoalSnapshot], todaySteps: Int?) {
        let d = UserDefaults.standard
        if let goal = GoalActionStore.shared.dailyStepGoal, case .steps(let minimum) = goal.requirement,
           let steps = todaySteps, steps < minimum {
            d.set(String(localized: "\((minimum - steps).formatted()) steps to your daily goal."), forKey: stepsKey)
        } else {
            d.removeObject(forKey: stepsKey)
        }

        let sleepGoal = periodSnapshots.contains {
            $0.goal.status == .active && ($0.goal.metric == .sleepNights || $0.goal.metric == .sleepAverage)
        }
        if d.bool(forKey: sleepKey) != sleepGoal {
            d.set(sleepGoal, forKey: sleepKey)
            WindDownNudge.refreshContentIfEnabled()
        }

        let training = periodSnapshots.filter {
            $0.goal.status == .active && $0.goal.period == .week && $0.goal.metric == .workouts
        }.map {
            TrainingLine(sports: $0.goal.sportFilter,
                         text: String(localized: "Counts toward \(GoalFormat.shortName($0.goal)) (\(GoalFormat.progress($0)))."))
        }
        if let data = try? JSONEncoder().encode(training) { d.set(data, forKey: trainingKey) }
    }
}

/// Goal events for the updates inbox: a goal reached (with the success haptic, once per goal and
/// period) and a finished week ready to review.
enum GoalEvents {
    private static let postedKey = "goals.events.posted"

    @MainActor
    static func announce(_ snapshots: [PeriodGoalSnapshot]) {
        var posted = Set(UserDefaults.standard.stringArray(forKey: postedKey) ?? [])
        var changed = false
        for snapshot in snapshots where snapshot.goal.status == .active && snapshot.state == .achieved {
            let key = "achieved:\(snapshot.id.uuidString):\(snapshot.periodStart)"
            guard !posted.contains(key) else { continue }
            posted.insert(key)
            changed = true
            AlertInbox.post(.goalAchieved, title: String(localized: "Goal reached"),
                            message: GoalFormat.title(snapshot.goal))
            StrandHaptic.success.play()
        }
        if let week = snapshots.first(where: { $0.goal.period == .week && $0.goal.status == .active && !$0.history.isEmpty }),
           week.todayIndex == 0 {
            let key = "review:\(week.periodStart)"
            if !posted.contains(key) {
                posted.insert(key)
                changed = true
                let last = snapshots.filter { $0.goal.period == .week }.compactMap(\.history.last)
                let reached = last.filter { $0.outcome == .achieved }.count
                AlertInbox.post(.goalReview, title: String(localized: "Your week in goals"),
                                message: String(localized: "\(reached) of \(last.count) goals reached last week."))
            }
        }
        if changed {
            // Keep the record small: only this year's keys matter.
            let trimmed = Array(posted.sorted().suffix(400))
            UserDefaults.standard.set(trimmed, forKey: postedKey)
        }
    }
}
