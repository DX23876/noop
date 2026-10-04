import Foundation
import StrandAnalytics
import WhoopStore

/// The motivation layer of the goals area (plan §17e): streaks of daily goals, badges, personal records.
/// Computed from history on every goals refresh (`GoalTrackingStore`), never stored; only which badges
/// the wearer has already seen is remembered. Switchable, on by default.
struct GoalMotivationSnapshot: Equatable {
    /// Days in a row per measured daily goal (steps, sleep, active kcal), keyed by the goal's id.
    var streaks: [UUID: GoalMotivation.Streak] = [:]
    var badges: [GoalMotivation.Badge] = []
    var records = GoalMotivation.Records()
    /// Today's steps beat every earlier day.
    var newStepRecordToday = false
    /// Measured steps today and in total, for the next-badge progress.
    var todaySteps: Int?
    var lifetimeSteps: Int = 0
    var stepStreakCurrent: Int = 0
    var reachedWeekCount: Int = 0
    var workoutCount: Int = 0

    var earned: [GoalMotivation.Badge] {
        badges.filter(\.isEarned).sorted { ($0.earnedOn ?? "", $0.threshold) > ($1.earnedOn ?? "", $1.threshold) }
    }

    /// Earned badges the wearer has not looked at yet.
    var unseen: [GoalMotivation.Badge] {
        let seen = GoalPrefs.seenBadgeIds
        return earned.filter { !seen.contains($0.id) }
    }

    /// The progress value a family's next badge is measured against.
    func progressValue(for family: GoalMotivation.BadgeFamily) -> Double {
        switch family {
        case .dailySteps: return Double(records.bestStepDay?.steps ?? 0)
        case .lifetimeSteps: return Double(lifetimeSteps)
        case .stepStreak: return Double(max(stepStreakCurrent, records.longestStepStreak))
        case .weeksReached: return Double(reachedWeekCount)
        case .workouts: return Double(workoutCount)
        }
    }
}

extension GoalPrefs {
    static let motivationEnabledKey = "goals.motivation.enabled"
    static let seenBadgesKey = "goals.motivation.seenBadges"

    /// Badges, streaks, records and cheering. On unless switched off.
    static var motivationEnabled: Bool {
        UserDefaults.standard.object(forKey: motivationEnabledKey) as? Bool ?? true
    }

    static var seenBadgeIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: seenBadgesKey) ?? [])
    }

    static func markBadgesSeen(_ ids: [String]) {
        let all = seenBadgeIds.union(ids)
        UserDefaults.standard.set(all.sorted(), forKey: seenBadgesKey)
    }
}

enum GoalMotivationBuilder {

    /// Measured steps per day: the strap's own count, else the same day's Health count. Never the
    /// motion estimate, the same rule as Today's step card (`DailyStepsReading`).
    static func stepsByDay(days: [DailyMetric], apple: [AppleDaily]) -> [String: Int] {
        var result: [String: Int] = [:]
        for row in apple { if let steps = row.steps, steps > 0 { result[row.day] = steps } }
        for day in days { if let steps = day.steps, steps > 0 { result[day.day] = steps } }
        return result
    }

    static func build(actions: [GoalAction], stepsByDay: [String: Int], days: [DailyMetric],
                      activeKcalByDay: [String: Double], workouts: [WorkoutRow],
                      periodSnapshots: [PeriodGoalSnapshot], frozen: [PeriodGoalResult],
                      periodGoals: [PeriodGoal], now: Date, calendar: Calendar) -> GoalMotivationSnapshot {
        let today = GoalActionEvaluator.dayKey(now, calendar: calendar)
        var snapshot = GoalMotivationSnapshot()
        let sleepByDay = Dictionary(days.compactMap { d in d.totalSleepMin.map { (d.day, $0 / 60) } },
                                    uniquingKeysWith: { a, _ in a })
        let stepValues = stepsByDay.mapValues(Double.init)
        let oldestData = [stepsByDay.keys.min(), sleepByDay.keys.min(), activeKcalByDay.keys.min()]
            .compactMap { $0 }.min() ?? today
        // A streak can reach back up to two years; older history adds nothing a badge can still use.
        let floor = GoalActionEvaluator.dayKey(calendar.date(byAdding: .day, value: -730, to: now) ?? now,
                                               calendar: calendar)
        let firstDay = max(oldestData, floor)

        // A goal's own streak starts the day it was set (Q4): a goal created today does not open on
        // "12 days in a row". Badges read the whole history below; a day of 15 000 steps is a fact.
        for action in actions where action.isActive && !action.hasEnded(today: today) {
            let created = GoalActionEvaluator.dayKey(action.createdAt, calendar: calendar)
            let values: [String: Double]
            let target: Double
            switch action.requirement {
            case .steps(let minimum): values = stepValues; target = Double(minimum)
            case .sleep(let hours): values = sleepByDay; target = hours
            case .activeCalories(let minimum): values = activeKcalByDay; target = Double(minimum)
            case .workout, .manual: continue
            }
            snapshot.streaks[action.id] = GoalMotivation.streak(
                values: values, target: target, firstDay: max(firstDay, created), today: today,
                isScheduled: { day in
                    guard let date = PeriodGoalTracker.date(day, calendar: calendar) else { return true }
                    return action.schedule.includes(date, calendar: calendar)
                })
        }

        // Step streak badges follow the daily step goal, or 10 000 steps while there is none.
        let stepGoal = actions.first { action in
            guard action.isActive, !action.hasEnded(today: today), case .steps = action.requirement else { return false }
            return true
        }
        let stepTarget: Double = {
            if let goal = stepGoal, case .steps(let minimum) = goal.requirement { return Double(minimum) }
            return 10_000
        }()
        let stepStreak = GoalMotivation.streak(values: stepValues, target: stepTarget, firstDay: firstDay, today: today)

        // Reached goal-weeks: the frozen results plus what is computed but not frozen yet, once each.
        let weekGoalIds = Set(periodGoals.filter { $0.period == .week }.map(\.id))
        var reached: [String: String] = [:]   // "goal|start" → end day of that week
        for result in frozen where weekGoalIds.contains(result.goalId) && result.outcome == .achieved {
            reached["\(result.goalId)|\(result.periodStart)"] = WeeklyDigestEngine.addDays(result.periodStart, 6)
        }
        for s in periodSnapshots where s.goal.period == .week {
            for entry in s.history where entry.outcome == .achieved {
                reached["\(s.id)|\(entry.periodStart)"] = WeeklyDigestEngine.addDays(entry.periodStart, 6)
            }
        }
        let workoutDays = workouts.map {
            GoalActionEvaluator.dayKey(Date(timeIntervalSince1970: Double($0.startTs)), calendar: calendar)
        }.filter { $0 <= today }

        snapshot.badges = GoalMotivation.badges(stepsByDay: stepsByDay, stepStreak: stepStreak,
                                                reachedWeeks: Array(reached.values), workoutDays: workoutDays)
        snapshot.records = GoalMotivation.records(stepsByDay: stepsByDay, workoutDays: workoutDays,
                                                  firstWeekday: calendar.firstWeekday,
                                                  longestStepStreak: stepStreak.best)
        snapshot.newStepRecordToday = GoalMotivation.isNewStepRecord(stepsByDay: stepsByDay, today: today)
        snapshot.todaySteps = stepsByDay[today]
        snapshot.lifetimeSteps = stepsByDay.values.reduce(0, +)
        snapshot.stepStreakCurrent = stepStreak.current
        snapshot.reachedWeekCount = reached.count
        snapshot.workoutCount = workoutDays.count
        return snapshot
    }
}
