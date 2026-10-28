import Foundation

/// Which screen a weekly goal belongs on (goals plan §2a, "goals where their context is"): training goals at the
/// top of the training hub, sleep goals on the sleep screen. Shared by Apple's `GoalsContextCard` and the Android
/// core (parity plan 2.3), so both platforms place a goal on the same screen.
enum GoalContext: String, CaseIterable {
    case training, sleep

    /// Whether an active weekly goal on `metric` belongs to this context.
    func includes(_ metric: PeriodMetric) -> Bool {
        switch self {
        case .training: return metric.isWorkoutBased || metric == .workingSets || metric == .restDays
        case .sleep: return metric == .sleepNights || metric == .sleepAverage
        }
    }

    /// The contexts an active weekly goal shows in; none for a paused, ended or monthly goal.
    static func contexts(of goal: PeriodGoal) -> [GoalContext] {
        guard goal.status == .active, goal.period == .week else { return [] }
        return allCases.filter { $0.includes(goal.metric) }
    }
}
