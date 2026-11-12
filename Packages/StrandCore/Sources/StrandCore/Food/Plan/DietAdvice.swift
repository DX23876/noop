import Foundation

/// This week's suggestions for the plan (owner, 2026-11-10): rules on what was logged, weighed and trained, at most
/// three, each with its reason and one action. The numbers they change go through `DietTargets` like any other
/// plan change; nothing here touches the plan by itself.
public enum DietAdvice {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// Protein below 80 % of the goal on the logged days.
        case proteinLow
        /// Fewer than three weigh-ins in seven days: the weekly check cannot see a trend.
        case weighMore
        /// Fewer than five logged days in seven: the weekly check holds.
        case logMore
        /// Gaining or recomposition, and the main lifts have not moved for four weeks: 100 kcal more.
        case strengthStalled
        /// Losing, and the trend has not moved for three weeks despite logged days: a break week instead of cutting.
        case lossStalled
    }

    public enum Action: String, Sendable, Codable {
        case showProteinFoods, openWeight, openLog, addKcal, takeBreakWeek
    }

    public struct Suggestion: Equatable, Sendable, Identifiable {
        public var kind: Kind
        public var action: Action
        public var id: String { kind.rawValue }

        public init(kind: Kind, action: Action) { self.kind = kind; self.action = action }
    }

    public struct Inputs: Equatable, Sendable {
        public var goal: DietPlan.Goal
        /// Mean protein on the logged days of the last seven, and the plan's protein goal.
        public var proteinMeanG: Double?
        public var proteinGoalG: Double
        public var weighInsLast7: Int
        public var loggedDaysLast7: Int
        /// Strength change in percent over the last four weeks; nil without enough sessions.
        public var strengthChange4WeeksPercent: Double?
        /// Weight trend in kilograms a week over the last three weeks; nil without enough weigh-ins.
        public var trend3WeeksKgPerWeek: Double?
        public var loggedDaysLast21: Int
        /// The plan already has a break this week or is past its goal.
        public var inBreakOrHolding: Bool
        /// The plan is at least this many days old.
        public var planAgeDays: Int

        public init(goal: DietPlan.Goal, proteinMeanG: Double?, proteinGoalG: Double, weighInsLast7: Int,
                    loggedDaysLast7: Int, strengthChange4WeeksPercent: Double?, trend3WeeksKgPerWeek: Double?,
                    loggedDaysLast21: Int, inBreakOrHolding: Bool, planAgeDays: Int) {
            self.goal = goal; self.proteinMeanG = proteinMeanG; self.proteinGoalG = proteinGoalG
            self.weighInsLast7 = weighInsLast7; self.loggedDaysLast7 = loggedDaysLast7
            self.strengthChange4WeeksPercent = strengthChange4WeeksPercent; self.trend3WeeksKgPerWeek = trend3WeeksKgPerWeek
            self.loggedDaysLast21 = loggedDaysLast21; self.inBreakOrHolding = inBreakOrHolding; self.planAgeDays = planAgeDays
        }
    }

    public static let maxShown = 3

    /// The suggestions, most useful first, without those dismissed this week.
    public static func suggestions(_ i: Inputs, dismissed: Set<Kind> = []) -> [Suggestion] {
        var out: [Suggestion] = []
        // Stalls first: they change the plan. Then the habits that make the weekly check work.
        if i.goal == .lose, !i.inBreakOrHolding, i.planAgeDays >= 28, i.loggedDaysLast21 >= 15,
           let trend = i.trend3WeeksKgPerWeek, trend > -0.1 {
            out.append(.init(kind: .lossStalled, action: .takeBreakWeek))
        }
        if i.goal == .gain || i.goal == .recomp, i.planAgeDays >= 28, let s = i.strengthChange4WeeksPercent, s < 1 {
            out.append(.init(kind: .strengthStalled, action: .addKcal))
        }
        if let mean = i.proteinMeanG, i.loggedDaysLast7 >= 3, i.proteinGoalG > 0, mean < i.proteinGoalG * 0.8 {
            out.append(.init(kind: .proteinLow, action: .showProteinFoods))
        }
        if i.weighInsLast7 < 3 { out.append(.init(kind: .weighMore, action: .openWeight)) }
        if i.loggedDaysLast7 < 5 { out.append(.init(kind: .logMore, action: .openLog)) }
        return Array(out.filter { !dismissed.contains($0.kind) }.prefix(maxShown))
    }

    /// The calories `addKcal` adds.
    public static let addKcalStep: Double = 100

    /// The plan after taking a suggestion that changes it; nil for one that only opens a page.
    public static func applying(_ s: Suggestion, to plan: DietPlan, today: String) -> DietPlan? {
        var next = plan
        switch s.action {
        case .addKcal: next.adjustmentKcal += addKcalStep; next.lastAdjustedDay = today
        case .takeBreakWeek: next.breakFromDay = today
        case .showProteinFoods, .openWeight, .openLog: return nil
        }
        return next
    }
}
