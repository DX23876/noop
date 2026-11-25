import Foundation
import StrandCore
import StrandAnalytics
import WhoopStore
import StrandDesign
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Optional system notifications for goals (off by default, Q4). Scheduled one-shot on each tracking
/// refresh from the latest state, through the same `UNCalendarNotificationTrigger` mechanism as the plan
/// reminders, and never inside the wearer's quiet hours.
enum GoalNotifier {
    static let weekStartId = PeriodGoalNoticePlan.weekStartId
    static let midWeekId = PeriodGoalNoticePlan.midWeekId
    static let reviewId = PeriodGoalNoticePlan.reviewId

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
        guard UserDefaults.standard.object(forKey: "notif.masterEnabled") as? Bool ?? true else { return }
        // What to say and when is `PeriodGoalNoticePlan`, which the Android app reads as well.
        let kinds = Set(GoalPrefs.NotificationKind.allCases.filter { GoalPrefs.notifies($0) })
        for notice in PeriodGoalNoticePlan.plan(snapshots, kinds: kinds, now: now,
                                               calendar: TrainingPreferences.weekCalendar,
                                               isQuiet: { isQuiet($0) }) {
            schedule(notice.id, title: notice.title, body: notice.body, at: notice.at)
        }
        #endif
    }

    /// The weekly goal the mid-week reminder speaks about: one clearly behind before one only close.
    static func slipping(_ week: [PeriodGoalSnapshot]) -> PeriodGoalSnapshot? {
        PeriodGoalMaintenance.slipping(week)
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

        let today = StoreReader.localDayKey(Date())
        let dailySleep = GoalActionStore.shared.actions.contains {
            guard $0.isActive, !$0.hasEnded(today: today), case .sleep = $0.requirement else { return false }
            return true
        }
        let sleepGoal = dailySleep || periodSnapshots.contains {
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
