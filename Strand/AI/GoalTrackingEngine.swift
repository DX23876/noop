import Foundation
import Combine
import WhoopStore

struct GoalMeasurement: Equatable {
    let value: Double
    let date: Date?
}

struct GoalTrackingSnapshot: Identifiable, Equatable {
    enum Health: Int, Equatable, CaseIterable {
        case decisionNeeded = 0
        case atRisk = 1
        case attention = 2
        case onTrack = 3
        case building = 4
        case paused = 5

        var label: String {
            switch self {
            case .decisionNeeded: return "Decision needed"
            case .atRisk:         return "At risk"
            case .attention:      return "Needs attention"
            case .onTrack:        return "On track"
            case .building:       return "Building evidence"
            case .paused:         return "Paused"
            }
        }
    }

    enum WeekState: Equatable { case successful, unsuccessful, protected, neutral, pending }

    struct GoalWeek: Identifiable, Equatable {
        let start: Date
        let planned: Int
        let completed: Int
        let open: Int
        let planPlanned: Int
        let planCompleted: Int
        let planOpen: Int
        let actionPlanned: Int
        let actionCompleted: Int
        let actionOpen: Int
        let state: WeekState
        var id: Date { start }
    }

    let id: UUID
    let goal: CoachGoal
    let measurement: GoalMeasurement?
    let progressFraction: Double?
    let trend: JourneyExplain.Trend
    let health: Health
    let reason: String
    let nextAction: String
    let currentWeek: GoalWeek
    let recentWeeks: [GoalWeek]
    let currentStreak: Int
    let bestStreak: Int

    var sortDate: Date { goal.targetDate ?? .distantFuture }
}

/// Pure goal monitoring. No model judgment and no persistence: the same snapshot can safely drive
/// Dashboard, Journey, Today, notifications and the coach context without five subtly different rules.
enum GoalTrackingEngine {
    static let successFraction = 0.8

    static func evaluate(goal: CoachGoal,
                         proposals: [PlanProposal],
                         actionOccurrences: [GoalActionOccurrence] = [],
                         measurement: GoalMeasurement?,
                         hasReconciliationQuestion: Bool = false,
                         now: Date = Date(),
                         calendar: Calendar = .autoupdatingCurrent) -> GoalTrackingSnapshot {
        let relevant = proposals.filter { $0.serves(goal.id) && $0.day >= dayKey(goal.createdAt, calendar: calendar) }
        let relevantActions = actionOccurrences.filter {
            $0.action.goalIds.contains(goal.id) && $0.day >= dayKey(goal.createdAt, calendar: calendar)
        }
        let currentInterval = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 86_400)
        let currentWeek = week(start: currentInterval.start, interval: currentInterval, goal: goal,
                               proposals: relevant, actions: relevantActions, isCurrent: true,
                               now: now, calendar: calendar)

        var completedWeeks: [GoalTrackingSnapshot.GoalWeek] = []
        var cursor = calendar.dateInterval(of: .weekOfYear, for: goal.createdAt)?.start
            ?? calendar.startOfDay(for: goal.createdAt)
        while cursor < currentInterval.start {
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor), next > cursor else { break }
            completedWeeks.append(week(start: cursor, interval: DateInterval(start: cursor, end: next),
                                       goal: goal, proposals: relevant, actions: relevantActions,
                                       isCurrent: false, now: now, calendar: calendar))
            cursor = next
        }

        let evaluated = completedWeeks.filter { $0.state == .successful || $0.state == .unsuccessful }
        var currentStreak = 0
        for item in completedWeeks.reversed() {
            switch item.state {
            case .successful: currentStreak += 1
            case .unsuccessful: break
            case .protected, .neutral, .pending: continue
            }
            if item.state == .unsuccessful { break }
        }
        var bestStreak = 0
        var run = 0
        for item in completedWeeks {
            switch item.state {
            case .successful:
                run += 1
                bestStreak = max(bestStreak, run)
            case .unsuccessful:
                run = 0
            case .protected, .neutral, .pending:
                continue
            }
        }

        let currentValue = measurement?.value
        let trend = JourneyExplain.trend(goal: goal, current: currentValue, now: now)
        let progress = progressFraction(goal: goal, current: currentValue)
        let expired = (ProactiveCoach.daysPastTarget(goal, now: now) ?? 0) >= 1
        let hasPastPending = completedWeeks.contains { $0.state == .pending }
        let recentEvaluated = Array(evaluated.suffix(2))
        let twoFailed = recentEvaluated.count == 2 && recentEvaluated.allSatisfy { $0.state == .unsuccessful }
        let latestFailed = evaluated.last?.state == .unsuccessful
        let planImpossible = currentWeek.planPlanned > 0
            && currentWeek.planCompleted + currentWeek.planOpen < requiredCompletions(for: currentWeek.planPlanned)
        let actionImpossible = currentWeek.actionPlanned > 0
            && currentWeek.actionCompleted + currentWeek.actionOpen < requiredCompletions(for: currentWeek.actionPlanned)
        let currentImpossible = planImpossible || actionImpossible
        let daysLeft = goal.targetDate.map {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                    to: calendar.startOfDay(for: $0)).day ?? Int.max
        }

        let health: GoalTrackingSnapshot.Health
        let reason: String
        let nextAction: String
        if goal.status == .paused {
            health = .paused
            reason = "Monitoring is frozen while this goal is paused."
            nextAction = "Resume when this goal fits again."
        } else if expired || hasReconciliationQuestion || hasPastPending {
            health = .decisionNeeded
            if expired {
                reason = "The target date has passed without a closing decision."
                nextAction = "Mark it achieved, extend the date, or set it aside."
            } else {
                reason = "A past commitment still needs to be resolved."
                nextAction = "Confirm what happened in Your plan."
            }
        } else if trend.verdict == .behind || twoFailed {
            health = .atRisk
            if trend.verdict == .behind {
                reason = "Measured progress is behind the pace of the target date."
                nextAction = "Review the target, date, or next plan with the coach."
            } else {
                reason = "Two evaluated goal weeks in a row fell below the execution plan."
                nextAction = "Make the next week smaller or easier to schedule."
            }
        } else if latestFailed || currentImpossible
                    || ((daysLeft.map { (0...14).contains($0) } ?? false)
                        && trend.verdict == .notMeasurable) {
            health = .attention
            if currentImpossible {
                reason = "This week's 80% execution threshold can no longer be reached."
                nextAction = "Adjust the remaining plan instead of trying to catch up blindly."
            } else if latestFailed {
                reason = "The latest evaluated goal week fell below the plan."
                nextAction = "Check what would make the next commitment easier to keep."
            } else {
                reason = "The target date is close, but there is not enough measured progress to judge it."
                nextAction = "Add a measurement or review the goal with the coach."
            }
        } else if trend.verdict == .ahead || trend.verdict == .onTrack
                    || evaluated.last?.state == .successful {
            health = .onTrack
            reason = trend.verdict == .ahead
                ? "Measured progress is ahead of the target-date pace."
                : "The latest available evidence is on track."
            nextAction = currentWeek.open > 0 ? "Complete the next planned commitment." : "Keep the next step realistic."
        } else {
            health = .building
            reason = "There is not enough measured or planned history for a stable call yet."
            nextAction = currentWeek.planned == 0 ? "Plan one concrete step for this goal." : "Keep building evidence."
        }

        return GoalTrackingSnapshot(id: goal.id, goal: goal, measurement: measurement,
                                    progressFraction: progress, trend: trend, health: health,
                                    reason: reason, nextAction: nextAction, currentWeek: currentWeek,
                                    recentWeeks: Array(completedWeeks.suffix(6)),
                                    currentStreak: currentStreak, bestStreak: bestStreak)
    }

    static func requiredCompletions(for planned: Int) -> Int {
        guard planned > 0 else { return 0 }
        return Int(ceil(Double(planned) * successFraction))
    }

    private static func week(start: Date, interval: DateInterval, goal: CoachGoal,
                             proposals: [PlanProposal], actions: [GoalActionOccurrence], isCurrent: Bool,
                             now: Date,
                             calendar: Calendar) -> GoalTrackingSnapshot.GoalWeek {
        let rows = proposals.filter { proposal in
            guard let date = date(from: proposal.day, calendar: calendar) else { return false }
            return interval.contains(date)
        }
        let commitments = rows.filter {
            switch $0.status {
            case .accepted, .modifiedByUser, .completed, .skipped, .rescheduled: return true
            case .proposed, .declined, .paused: return false
            }
        }
        let completed = commitments.filter { $0.status == .completed }.count
        let open = commitments.filter {
            $0.status == .accepted || $0.status == .modifiedByUser || $0.status == .rescheduled
        }.count
        let actionRows = actions.filter { action in
            guard let date = date(from: action.day, calendar: calendar) else { return false }
            return interval.contains(date)
        }
        let actionCompleted = actionRows.filter(\.isCompleted).count
        let today = dayKey(now, calendar: calendar)
        let actionOpen = actionRows.filter { !$0.isCompleted && $0.day >= today }.count
        let protectedReason = rows.contains {
            $0.status == .paused || ($0.status == .skipped && isProtected($0.skipReason))
        }
        let protectedPause = goal.pauseIntervals.contains { $0.intersects(interval) }

        let state: GoalTrackingSnapshot.WeekState
        if protectedReason || protectedPause {
            state = .protected
        } else if commitments.isEmpty && actionRows.isEmpty {
            state = .neutral
        } else if isCurrent {
            state = .pending
        } else if open > 0 {
            state = .pending
        } else if laneSucceeded(completed: completed, planned: commitments.count)
                    && laneSucceeded(completed: actionCompleted, planned: actionRows.count) {
            state = .successful
        } else {
            state = .unsuccessful
        }
        return .init(start: start, planned: commitments.count + actionRows.count,
                     completed: completed + actionCompleted, open: open + actionOpen,
                     planPlanned: commitments.count, planCompleted: completed, planOpen: open,
                     actionPlanned: actionRows.count, actionCompleted: actionCompleted,
                     actionOpen: actionOpen, state: state)
    }

    private static func laneSucceeded(completed: Int, planned: Int) -> Bool {
        planned == 0 || completed >= requiredCompletions(for: planned)
    }

    private static func isProtected(_ reason: PlanProposal.SkipReason?) -> Bool {
        reason == .ill || reason == .pain || reason == .travel
    }

    private static func progressFraction(goal: CoachGoal, current: Double?) -> Double? {
        guard goal.kind.isQuantified, let current, let baseline = goal.baseline,
              let target = goal.target, baseline != target else { return nil }
        return min(1, max(0, (current - baseline) / (target - baseline)))
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func date(from day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

@MainActor
final class GoalTrackingStore: ObservableObject {
    static let shared = GoalTrackingStore()

    @Published private(set) var snapshots: [GoalTrackingSnapshot] = []
    @Published private(set) var todayActions: [GoalActionOccurrence] = []
    @Published private(set) var pendingWorkoutAttributions: [GoalWorkoutAttributionSuggestion] = []
    @Published private(set) var lastUpdated: Date?

    func snapshot(for goalId: UUID) -> GoalTrackingSnapshot? {
        snapshots.first { $0.id == goalId }
    }

    func refresh(repo: Repository, now: Date = Date()) async {
        await refresh(repo: repo, now: now, goals: CoachGoalStore.shared.goals,
                      proposals: CoachPlanStore.shared.proposals,
                      resolutions: CoachPlanStore.shared.reconciliationResolutions,
                      actions: GoalActionStore.shared.actions,
                      checkoffs: GoalActionStore.shared.checkoffs,
                      contributions: GoalContributionStore.shared.contributions,
                      dismissedWorkoutKeys: GoalContributionStore.shared.dismissedWorkoutKeys)
    }

    func refresh(repo: Repository, now: Date,
                 goals: [CoachGoal], proposals: [PlanProposal],
                 resolutions: [PlanReconciliationResolution],
                 actions: [GoalAction] = [], checkoffs: [GoalActionCheckoff] = [],
                 contributions: [GoalWorkoutContribution] = [],
                 dismissedWorkoutKeys: Set<String> = []) async {
        let workouts = await repo.workoutRows(days: 365)
        let weights = await repo.series(key: "weight", source: "apple-health", days: 365)
        let measurementByKind = measurements(workouts: workouts, weights: weights,
                                             days: repo.days, now: now)
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.date(byAdding: .day, value: -365, to: now) ?? now
        let end = calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? now
        let activeGoalIds = Set(goals.filter { $0.status == .active }.map(\.id))
        let actionOccurrences = GoalActionEvaluator.occurrences(
            actions: actions, checkoffs: checkoffs, activeGoalIds: activeGoalIds,
            days: repo.days, workouts: workouts, from: start, through: end, calendar: calendar)
        let today = GoalActionEvaluator.dayKey(now, calendar: calendar)
        todayActions = actionOccurrences.filter { $0.day == today }
        let consumedWorkoutKeys = Set(proposals.compactMap { $0.completionEvidence?.workoutKey })
            .union(contributions.map(\.id)).union(dismissedWorkoutKeys)
        let workoutRowsByKey = Dictionary(workouts.map { (PlanWorkoutReference($0).workoutKey, $0) },
                                          uniquingKeysWith: { first, _ in first })
        let attributionCutoff = now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        pendingWorkoutAttributions = workouts
            .filter { Double($0.startTs) >= attributionCutoff && Double($0.startTs) <= now.timeIntervalSince1970 }
            .map(PlanWorkoutReference.init)
            .filter { !consumedWorkoutKeys.contains($0.workoutKey) }
            .filter { workout in
                guard let row = workoutRowsByKey[workout.workoutKey] else { return true }
                let workoutDate = Date(timeIntervalSince1970: Double(row.startTs))
                return !actions.contains { action in
                    guard action.isActive,
                          case .workout = action.requirement else { return false }
                    return GoalActionEvaluator.isDue(action, on: workoutDate,
                                                     activeGoalIds: activeGoalIds, calendar: calendar)
                        && GoalActionEvaluator.automaticCompletion(action.requirement,
                                                                   metric: nil, workouts: [row])
                }
            }
            .compactMap { workout in
                let suggested = GoalAttributionSuggester.suggestedGoalIds(for: workout.sport,
                                                                          goals: goals)
                return suggested.isEmpty ? nil : .init(workout: workout, suggestedGoalIds: suggested)
            }
            .sorted { $0.workout.startTs > $1.workout.startTs }
        let unresolved = Set(resolutions.map(\.proposalId))
        snapshots = goals.map { goal in
            GoalTrackingEngine.evaluate(goal: goal, proposals: proposals,
                                        actionOccurrences: actionOccurrences,
                                        measurement: measurementByKind[goal.kind],
                                        hasReconciliationQuestion: proposals.contains {
                                            $0.serves(goal.id) && unresolved.contains($0.id)
                                        }, now: now)
        }
        lastUpdated = now
        CoachNotifier.syncGoalMonitoring(snapshots)
    }

    private func measurements(workouts: [WorkoutRow], weights: [(day: String, value: Double)],
                              days: [DailyMetric], now: Date) -> [CoachGoal.Kind: GoalMeasurement] {
        var result: [CoachGoal.Kind: GoalMeasurement] = [:]
        let runs = workouts.filter { $0.sport.lowercased().contains("run") && ($0.distanceM ?? 0) > 0 }
        if let longest = runs.max(by: { ($0.distanceM ?? 0) < ($1.distanceM ?? 0) }) {
            result[.run] = GoalMeasurement(value: (longest.distanceM ?? 0) / 1000,
                                           date: Date(timeIntervalSince1970: Double(longest.startTs)))
        }
        let cutoff = now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970
        let recentWorkouts = workouts.filter { Double($0.startTs) >= cutoff }
        if !recentWorkouts.isEmpty {
            let latest = recentWorkouts.map(\.startTs).max().map { Date(timeIntervalSince1970: Double($0)) }
            result[.consistency] = GoalMeasurement(value: Double(recentWorkouts.count) / (30.0 / 7.0), date: latest)
        }
        let recentDays = Array(days.sorted { $0.day < $1.day }.suffix(14))
        let sleeps = recentDays.compactMap { $0.totalSleepMin }
        if !sleeps.isEmpty {
            let lastDay = recentDays.last(where: { $0.totalSleepMin != nil })?.day
            result[.sleep] = GoalMeasurement(value: sleeps.reduce(0, +) / Double(sleeps.count) / 60,
                                             date: lastDay.flatMap(parseDay))
        }
        if let weight = weights.sorted(by: { $0.day < $1.day }).last {
            result[.weight] = GoalMeasurement(value: weight.value, date: parseDay(weight.day))
        }
        return result
    }

    private func parseDay(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.autoupdatingCurrent.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
