import Foundation
import StrandAnalytics

/// Each goal as a program (owner, 2026-11-10): what it does through the weeks, so losing, holding, gaining and
/// recomposition get the same depth. `DietTargets` still works out the numbers; this says which phase a day is in
/// and what the program sets unless the wearer chose otherwise.
///
/// - Losing: the deficit, a week at maintenance every seven weeks (simple mode; advanced sets its own), and at the
///   goal weight a week at half the deficit before holding.
/// - Gaining: a small surplus, and at the goal weight the same step down to holding.
/// - Holding and recomposition: no phases; the weekly check keeps the weight in a band.
/// Training days take 10 % more of the day for every goal but holding, where it is the wearer's choice.
public enum DietProgram {
    public enum Phase: String, Equatable, Sendable, Codable {
        case main
        /// A week at maintenance inside a deficit.
        case dietBreak
        /// The first week after reaching the goal weight: half the plan's change.
        case transition
        /// The goal weight is reached: eat what you burn.
        case holding

        /// How much of the plan's daily change (deficit or surplus) the phase keeps.
        public var deltaFactor: Double {
            switch self {
            case .main: 1
            case .transition: 0.5
            case .dietBreak, .holding: 0
            }
        }
    }

    /// The share of the eating day a training day gets by default.
    public static func defaultDayShift(_ goal: DietPlan.Goal) -> Double {
        switch goal {
        case .lose, .gain, .recomp: 0.10
        case .maintain: 0
        }
    }

    /// Weeks between diet breaks the program sets: losing every seven weeks in the simple mode; the advanced mode
    /// takes the wearer's own setting, none when they set none.
    public static func dietBreakEveryWeeks(_ plan: DietPlan) -> Int? {
        if plan.mode == .advanced { return plan.dietBreakEveryWeeks.flatMap { $0 > 0 ? $0 : nil } }
        return plan.goal == .lose ? 7 : nil
    }

    public static let transitionDays = 7
    public static let breakDays = 7

    /// The first day the smoothed weight trend reached the goal weight in the plan's direction, never one weigh-in.
    public static func goalReachedDay(plan: DietPlan, goalWeightKg: Double?, weighIns: [(day: String, kg: Double)]) -> String? {
        guard let goal = goalWeightKg, plan.goal == .lose || plan.goal == .gain else { return nil }
        let samples = weighIns.filter { $0.day >= plan.startDay }
            .compactMap { w in WeightSeries.date(forDay: w.day).map { (date: $0, value: w.kg, day: w.day) } }
            .sorted { $0.date < $1.date }
        let smoothed = WeightTrendSummary.smoothedSeries(samples.map { ($0.date, $0.value) })
        for (point, sample) in zip(smoothed, samples) {
            let reached = plan.goal == .lose ? point.value <= goal : point.value >= goal
            if reached { return sample.day }
        }
        return nil
    }

    /// The phase of `day`. `goalReachedDay` comes from `goalReachedDay(...)`.
    public static func phase(on day: String, plan: DietPlan, goalReachedDay: String?, calendar: Calendar = .current) -> Phase {
        if let reached = goalReachedDay, let from = WeightSeries.date(forDay: reached), let date = WeightSeries.date(forDay: day),
           date >= from {
            let days = calendar.dateComponents([.day], from: from, to: date).day ?? 0
            return days < transitionDays ? .transition : .holding
        }
        guard let date = WeightSeries.date(forDay: day) else { return .main }
        // A break the wearer took on a suggestion runs a week from its first day.
        if let breakFrom = plan.breakFromDay.flatMap(WeightSeries.date(forDay:)) {
            let days = calendar.dateComponents([.day], from: breakFrom, to: date).day ?? -1
            if days >= 0 && days < breakDays { return .dietBreak }
        }
        if plan.goal == .lose, let every = dietBreakEveryWeeks(plan), let start = WeightSeries.date(forDay: plan.startDay) {
            let days = calendar.dateComponents([.day], from: start, to: date).day ?? -1
            // Week 1 starts with the plan; the same weeks `DietForecast` marks as breaks.
            if days >= 0, (days / 7 + 1) % (every + 1) == 0 { return .dietBreak }
        }
        return .main
    }
}

/// The days a plan counts as training days: those the training planner has a session on, and those with logged
/// strength training. The weekday choice in the diet plan stands in only for weeks the training planner leaves
/// empty.
public struct DietTrainingDays: Equatable, Sendable {
    public var planned: Set<String>
    public var logged: Set<String>

    public init(planned: Set<String> = [], logged: Set<String> = []) {
        self.planned = planned; self.logged = logged
    }

    /// The weekdays (1 Sunday … 7 Saturday) the wearer usually trains, from logged strength days of the last four
    /// weeks: each weekday trained at least twice, the five most frequent, in week order. The planner proposes them.
    public static func usualWeekdays(logged: Set<String>, today: Date = Date(), calendar: Calendar = .current) -> [Int] {
        guard let cutoffDate = calendar.date(byAdding: .day, value: -28, to: today) else { return [] }
        let f = DateFormatter()
        f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        let cutoff = f.string(from: cutoffDate)
        var counts: [Int: Int] = [:]
        for day in logged where day >= cutoff {
            if let date = WeightSeries.date(forDay: day) { counts[calendar.component(.weekday, from: date), default: 0] += 1 }
        }
        return counts.filter { $0.value >= 2 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5).map(\.key).sorted()
    }
}
