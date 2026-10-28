import Foundation
import StrandCore
import WhoopStore

/// The one-line goal notes beside a workout and a night (goals plan §8a and §2a): what a saved workout counted
/// toward, what a session about to be saved adds, and where a night stands in the week's sleep goals. Shared by the
/// Apple notes and the Android core (parity plan 2.3), so both platforms say the same thing from the same snapshots.
enum GoalContextLines {
    struct Preview: Identifiable, Equatable {
        let id: UUID
        let text: String
        let reaches: Bool
    }

    /// "Counts toward Runs: 3/4" for each active goal a saved workout counts toward. A workout the current period
    /// has not seen yet (just saved, not refreshed) is matched by the goal's own sport rule.
    static func contributions(_ snapshots: [PeriodGoalSnapshot], row: WorkoutRow) -> [String] {
        let key = PlanWorkoutReference(row).workoutKey
        let day = StoreReader.localDayKey(Date(timeIntervalSince1970: Double(row.startTs)))
        return snapshots.filter { snapshot in
            guard snapshot.goal.status == .active, snapshot.goal.metric.isWorkoutBased,
                  snapshot.periodDays.contains(day) else { return false }
            if snapshot.counted.contains(where: { $0.id == key }) { return true }
            if snapshot.notCounted.contains(where: { $0.id == key }) { return false }
            return PeriodGoalTracker.workoutMatches(snapshot.goal, row)
        }
        .map { String(localized: "Counts toward \(GoalFormat.shortName($0.goal)): \(GoalFormat.progress($0))") }
    }

    /// What a session about to be saved adds to this week's and month's goals ("With this session: Workouts 4/4").
    /// The snapshots have not seen the session yet, so its share is added by the goal's own rules: one workout, its
    /// minutes, its working sets.
    static func sessionPreview(_ snapshots: [PeriodGoalSnapshot], row: WorkoutRow, workingSets: Int) -> [Preview] {
        let day = StoreReader.localDayKey(Date(timeIntervalSince1970: Double(row.startTs)))
        return snapshots.compactMap { snapshot in
            let goal = snapshot.goal
            guard goal.status == .active, snapshot.periodDays.contains(day) else { return nil }
            let added: Double
            if goal.metric == .workingSets {
                added = Double(workingSets)
            } else if goal.metric.isWorkoutBased, PeriodGoalTracker.workoutMatches(goal, row) {
                added = goal.metric == .workouts ? 1 : (PeriodGoalTracker.workoutAmount(goal.metric, row) ?? 0)
            } else {
                return nil
            }
            guard added > 0 else { return nil }
            let before = snapshot.result.current
            let after = before + added
            let target = snapshot.result.target
            let name = GoalFormat.shortName(goal)
            let progress = "\(GoalFormat.number(after, goal.metric))/\(GoalFormat.number(target, goal.metric))"
            let reaches = before < target && after >= target
            return Preview(id: goal.id, text: reaches ? String(localized: "This session reaches \(name): \(progress)")
                                                      : String(localized: "With this session: \(name) \(progress)"),
                           reaches: reaches)
        }
    }

    /// Where the night ending on `day` stands in this week's sleep goals: "Night 3 of 5 of 7.5 h this week" when it
    /// counted, the shortfall when it did not, the running average for an average goal. Empty when the night has no
    /// sleep reading or no weekly sleep goal covers it.
    static func night(_ snapshots: [PeriodGoalSnapshot], day: String) -> [String] {
        snapshots.compactMap { snapshot in
            let goal = snapshot.goal
            guard goal.status == .active, goal.period == .week,
                  let index = snapshot.periodDays.firstIndex(of: day),
                  snapshot.dayValues.indices.contains(index), let value = snapshot.dayValues[index] else { return nil }
            let target = GoalFormat.number(snapshot.result.target, goal.metric)
            switch goal.metric {
            case .sleepNights:
                let hours = (goal.threshold ?? 7).formatted(.number.precision(.fractionLength(0...1)))
                let sofar = snapshot.dayValues[...index].compactMap { $0 }.filter { $0 >= 1 }.count
                if value >= 1 {
                    return String(localized: "Night \(sofar) of \(target) of \(hours) h this week")
                }
                return String(localized: "Under \(hours) h, so it does not count: \(sofar) of \(target) nights so far")
            case .sleepAverage:
                return String(localized: "Average this week: \(GoalFormat.amount(snapshot.result.current, goal.metric)) of \(GoalFormat.amount(snapshot.result.target, goal.metric))")
            default:
                return nil
            }
        }
    }
}
