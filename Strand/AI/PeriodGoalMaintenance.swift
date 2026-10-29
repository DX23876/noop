import Foundation
import StrandAnalytics

/// Pure period-goal adjustments, upkeep and reminder selection, shared by both hosts.
enum PeriodGoalMaintenance {
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

    static func slipping(_ week: [PeriodGoalSnapshot]) -> PeriodGoalSnapshot? {
        week.first { $0.state == .behind } ?? week.first { $0.state == .close }
    }

    static func needsAttention(_ state: PeriodGoalState) -> Bool { state == .close || state == .behind }

    static func weeklyShortfall(_ snapshots: [PeriodGoalSnapshot]) -> (planned: Int, done: Int, daysLeft: Int)? {
        guard let snapshot = snapshots.first(where: {
            $0.goal.status == .active && $0.goal.period == .week && $0.goal.metric == .workouts
                && needsAttention($0.state)
        }) else { return nil }
        return (Int(snapshot.result.target.rounded()), Int(snapshot.result.current.rounded()), max(1, snapshot.daysLeft))
    }
}
