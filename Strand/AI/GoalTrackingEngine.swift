import Foundation
import WhoopStore
import StrandAnalytics
import StrandCore

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
    /// Progress from baseline to target, clamped to 0...1 — the length of a progress bar.
    let progressFraction: Double?
    /// The SAME ratio unclamped. The clamped one cannot distinguish "hasn't started" from "moved
    /// backwards past the starting point" (both read 0) or "just reached it" from "well past it"
    /// (both read 1), so the honest value travels alongside for anything that puts it into words.
    let rawProgressFraction: Double?
    let trend: JourneyExplain.Trend
    var health: Health
    var reason: String
    var nextAction: String
    let currentWeek: GoalWeek
    let recentWeeks: [GoalWeek]
    let currentStreak: Int
    let bestStreak: Int
    /// The next waypoint the route has not reached yet, or nil (no route, or all of them passed).
    let nextMilestone: CoachGoal.Milestone?
    /// Where the plan says you should be today, how far off that is, and — only when the measured
    /// trend supports one — an arrival date. Nil for a goal with no start/target/date.
    let course: GoalMilestones.Course?
    /// A catalog goal's reading for its page (`LongTermGoalReader`); nil for goals measured by kind.
    var reading: GoalShapeReading? = nil

    var sortDate: Date { goal.targetDate ?? .distantFuture }

    /// Progress for a bar: the catalog reading's where there is one, else the kind's.
    var displayProgress: Double? { reading?.progress ?? progressFraction }

    /// The snapshot with a catalog reading attached. Its state replaces the kind-based verdict, which
    /// cannot know what a catalog goal measures; a paused goal and an open decision keep theirs.
    func applying(_ reading: GoalShapeReading?) -> GoalTrackingSnapshot {
        var copy = self
        copy.reading = reading
        guard let reading, health != .paused, health != .decisionNeeded else { return copy }
        switch reading.state {
        case .achieved?, .ahead?, .onTrack?:
            copy.health = .onTrack
            copy.reason = "The goal's own measure is on track."
            copy.nextAction = "Keep the week going."
        case .close?:
            copy.health = .attention
            copy.reason = "The goal's own measure is a little behind."
            copy.nextAction = "This week's goal shows what closes the gap."
        case .behind?, .outOfReach?:
            copy.health = .atRisk
            copy.reason = "The goal's own measure is behind."
            copy.nextAction = "Review the target, the date or this week's goal."
        case .starting?, .noData?, .protected?, nil:
            copy.health = .building
            copy.reason = "There is not enough measured data for a call yet."
            copy.nextAction = "Keep going; the page fills in as data arrives."
        }
        return copy
    }
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
                         courseSeries: [GoalMilestones.Sample] = [],
                         now: Date = Date(),
                         calendar: Calendar = .autoupdatingCurrent) -> GoalTrackingSnapshot {
        // Hoisted: this depends only on the goal, but sat inside both filter closures below — a
        // `dateComponents` + `String(format:)` per row, on every evaluate.
        let createdKey = dayKey(goal.createdAt, calendar: calendar)
        let relevant = proposals.filter { $0.serves(goal.id) && $0.day >= createdKey }
        let relevantActions = actionOccurrences.filter {
            $0.action.goalIds.contains(goal.id) && $0.day >= createdKey
        }
        let currentInterval = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 86_400)

        // Bucket ONCE by the week each row falls in, instead of re-scanning (and re-parsing) the whole
        // list for every week of the walk below. The walk's cursors are calendar week starts, so a
        // row's own week start is the same key — the grouping is identical, the cost is not: this
        // turns weeks × rows date constructions into one per row.
        let proposalsByWeek = bucketByWeek(relevant, day: \.day, calendar: calendar)
        let actionsByWeek = bucketByWeek(relevantActions, day: \.day, calendar: calendar)

        let currentWeek = week(start: currentInterval.start, interval: currentInterval, goal: goal,
                               rows: proposalsByWeek[currentInterval.start] ?? [],
                               actionRows: actionsByWeek[currentInterval.start] ?? [],
                               isCurrent: true, now: now, calendar: calendar)

        var completedWeeks: [GoalTrackingSnapshot.GoalWeek] = []
        var cursor = calendar.dateInterval(of: .weekOfYear, for: goal.createdAt)?.start
            ?? calendar.startOfDay(for: goal.createdAt)
        let walkLimit = weekWalkLimit(goal: goal, currentWeekStart: currentInterval.start,
                                      calendar: calendar)
        while cursor < walkLimit {
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor), next > cursor else { break }
            completedWeeks.append(week(start: cursor, interval: DateInterval(start: cursor, end: next),
                                       goal: goal,
                                       rows: proposalsByWeek[cursor] ?? [],
                                       actionRows: actionsByWeek[cursor] ?? [],
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
        let rawProgress = rawProgressFraction(goal: goal, current: currentValue)
        let progress = rawProgress.map { min(1, max(0, $0)) }
        let expired = (goal.daysPastTarget(now: now) ?? 0) >= 1
        let hasPastPending = completedWeeks.contains { $0.state == .pending }
        let recentEvaluated = Array(evaluated.suffix(2))
        let twoFailed = recentEvaluated.count == 2 && recentEvaluated.allSatisfy { $0.state == .unsuccessful }
        let latestFailed = evaluated.last?.state == .unsuccessful
        let planImpossible = currentWeek.planPlanned > 0
            && currentWeek.planCompleted + currentWeek.planOpen < requiredCompletions(for: currentWeek.planPlanned)
        let actionImpossible = currentWeek.actionPlanned > 0
            && currentWeek.actionCompleted + currentWeek.actionOpen < requiredCompletions(for: currentWeek.actionPlanned)
        let currentImpossible = planImpossible || actionImpossible
        // A smoothed value that is still cold-starting may be SHOWN but must not produce a verdict —
        // an "at risk" derived from four days of scale readings is noise wearing a conclusion's hat.
        let judgeable = !(measurement?.isProvisional ?? false)
        // A goal NOOP cannot measure at all (custom, or one without target/date). Previously such a
        // goal sat on "building evidence" for its whole life and then flipped to "needs attention"
        // inside the last 14 days before its target date — an alarm nobody could ever resolve,
        // because no measurement was coming. It now keeps an honest held state instead.
        let unmeasurable = trend.verdict == .notMeasurable && measurement == nil

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
        } else if (trend.verdict == .behind && judgeable) || twoFailed {
            health = .atRisk
            if trend.verdict == .behind {
                reason = "Measured progress is behind the pace of the target date."
                nextAction = "Review the target, date, or next plan with the coach."
            } else {
                reason = "Two evaluated goal weeks in a row fell below the execution plan."
                nextAction = "Make the next week smaller or easier to schedule."
            }
        } else if latestFailed || currentImpossible {
            health = .attention
            if currentImpossible {
                // Name the REAL threshold. The copy used to claim a flat "80%", which was never what
                // the rule computed for a small week.
                let planned = max(currentWeek.planPlanned, currentWeek.actionPlanned)
                reason = "This week needs \(requiredCompletions(for: planned)) of \(planned) — that can no longer be reached."
                nextAction = "Adjust the remaining plan instead of trying to catch up blindly."
            } else {
                reason = "The latest evaluated goal week fell below the plan."
                nextAction = "Check what would make the next commitment easier to keep."
            }
        } else if (trend.verdict == .ahead || trend.verdict == .onTrack) && judgeable
                    || evaluated.last?.state == .successful {
            health = .onTrack
            reason = trend.verdict == .ahead
                ? "Measured progress is ahead of the target-date pace."
                : "The latest available evidence is on track."
            nextAction = currentWeek.open > 0 ? "Complete the next planned commitment." : "Keep the next step realistic."
        } else if unmeasurable {
            health = .building
            reason = "This goal is held, not measured — NOOP has no number that tracks it."
            nextAction = currentWeek.planned == 0
                ? "Plan a concrete step, or talk it through with the coach."
                : "Keep the planned steps going."
        } else {
            health = .building
            reason = "There is not enough measured or planned history for a stable call yet."
            nextAction = currentWeek.planned == 0 ? "Plan one concrete step for this goal." : "Keep building evidence."
        }

        // The route and the course reading. Both need a start, a target and a date; without them the
        // goal simply has no plan to be measured against, which is a normal state, not an error.
        let nextMilestone = goal.milestones
            .filter { $0.achievedAt == nil }
            .min { $0.expectedDate < $1.expectedDate }
        let course: GoalMilestones.Course? = {
            // `judgeable` gates this for the same reason it gates the health verdict above: a Course
            // carries `verdict` (.ahead/.behind/.onCourse) and `daysLate`, which are judgements, not
            // readings. Deriving them from a still-cold-starting trend produces a confident arrival
            // date out of four scale readings.
            guard judgeable,
                  let baseline = goal.baseline, let target = goal.target,
                  let targetDate = goal.targetDate, let currentValue else { return nil }
            return GoalMilestones.course(baseline: baseline, target: target,
                                          createdAt: goal.createdAt, targetDate: targetDate,
                                          current: currentValue, series: courseSeries, now: now)
        }()

        return GoalTrackingSnapshot(id: goal.id, goal: goal, measurement: measurement,
                                    progressFraction: progress, rawProgressFraction: rawProgress,
                                    trend: trend, health: health,
                                    reason: reason, nextAction: nextAction, currentWeek: currentWeek,
                                    recentWeeks: Array(completedWeeks.suffix(6)),
                                    currentStreak: currentStreak, bestStreak: bestStreak,
                                    nextMilestone: nextMilestone, course: course)
    }

    /// Forwards to the tested rule in `GoalMeasure`. Kept as an entry point here because call sites
    /// (and the UI copy) already speak in terms of the engine.
    static func requiredCompletions(for planned: Int) -> Int {
        GoalMeasure.requiredCompletions(for: planned, successFraction: successFraction)
    }

    /// Group rows by the START of the calendar week they fall in, parsing each `yyyy-MM-dd` exactly
    /// once. Rows whose day cannot be parsed are dropped, matching the old per-week filter's `guard`.
    private static func bucketByWeek<T>(_ rows: [T], day: KeyPath<T, String>,
                                        calendar: Calendar) -> [Date: [T]] {
        var buckets: [Date: [T]] = [:]
        // Days repeat heavily across rows (several sessions on one day, a year of daily actions), so
        // the parse is memoised per distinct day string rather than per row.
        var weekStartByDay: [String: Date?] = [:]
        for row in rows {
            let key = row[keyPath: day]
            let weekStart: Date?
            if let cached = weekStartByDay[key] {
                weekStart = cached
            } else {
                weekStart = date(from: key, calendar: calendar)
                    .flatMap { calendar.dateInterval(of: .weekOfYear, for: $0)?.start }
                weekStartByDay[key] = weekStart
            }
            guard let weekStart else { continue }
            buckets[weekStart, default: []].append(row)
        }
        return buckets
    }

    /// Where the week walk stops. For an open goal that is the current week; for a CLOSED one it is the
    /// week it closed in.
    ///
    /// A closed goal used to keep accruing weeks up to today forever — so the cost of a goal abandoned
    /// last spring grew by one more week every week, permanently, and the record gained "neutral"
    /// weeks for a period when nobody was pursuing it. Goals are never pruned automatically, so that
    /// accumulated across every goal a person had ever closed.
    private static func weekWalkLimit(goal: CoachGoal, currentWeekStart: Date,
                                      calendar: Calendar) -> Date {
        guard let closure = goal.closure else { return currentWeekStart }
        guard let closureWeekStart = calendar.dateInterval(of: .weekOfYear, for: closure.date)?.start,
              // The week it closed in is still a week it lived through, so the walk includes it.
              let afterClosureWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: closureWeekStart)
        else { return currentWeekStart }
        return min(currentWeekStart, afterClosureWeek)
    }

    /// One week's accounting. `rows`/`actionRows` are ALREADY scoped to this week by the caller's
    /// bucketing — `interval` remains only for the pause check, which tests an overlap rather than
    /// membership.
    private static func week(start: Date, interval: DateInterval, goal: CoachGoal,
                             rows: [PlanProposal], actionRows: [GoalActionOccurrence], isCurrent: Bool,
                             now: Date,
                             calendar: Calendar) -> GoalTrackingSnapshot.GoalWeek {
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

    /// Signed by the goal's own direction, so a weight goal counting DOWN reads the same way up as a
    /// distance goal counting up. Unclamped; callers clamp for a bar.
    private static func rawProgressFraction(goal: CoachGoal, current: Double?) -> Double? {
        guard goal.kind.isQuantified, let current, let baseline = goal.baseline,
              let target = goal.target, baseline != target else { return nil }
        return (current - baseline) / (target - baseline)
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
