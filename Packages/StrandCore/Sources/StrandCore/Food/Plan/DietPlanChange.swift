import Foundation

/// A change to the diet plan the coach proposed (owner, 2026-11-10). It waits on the plan page until the wearer
/// confirms it, and then goes through `apply` and `DietTargets` like a change made in the planner, so every
/// safety line holds. Unknown or out-of-range values are dropped, never guessed.
public struct DietPlanChange: Codable, Equatable, Sendable {
    public var goal: DietPlan.Goal?
    public var pacePercent: Double?
    public var form: DietForm?
    public var dietBreakEveryWeeks: Int?
    public var dayShift: Double?
    /// Take a week at maintenance from today.
    public var breakWeekNow: Bool?
    public var rationale: String
    public var createdAt: Int

    public init(goal: DietPlan.Goal? = nil, pacePercent: Double? = nil, form: DietForm? = nil,
                dietBreakEveryWeeks: Int? = nil, dayShift: Double? = nil, breakWeekNow: Bool? = nil,
                rationale: String, createdAt: Int) {
        self.goal = goal; self.pacePercent = pacePercent; self.form = form
        self.dietBreakEveryWeeks = dietBreakEveryWeeks; self.dayShift = dayShift; self.breakWeekNow = breakWeekNow
        self.rationale = rationale; self.createdAt = createdAt
    }

    /// The preference key the pending change waits under, the same on both platforms.
    public static let storageKey = "food.plan.coachProposal"

    /// True when nothing would change.
    public var isEmpty: Bool {
        goal == nil && pacePercent == nil && form == nil && dietBreakEveryWeeks == nil && dayShift == nil && breakWeekNow != true
    }

    /// Builds a change from the coach's tool input, keeping only values the planner itself allows.
    public static func parse(_ input: [String: Any], now: Int) -> DietPlanChange {
        func number(_ key: String) -> Double? {
            if let d = input[key] as? Double { return d }
            if let i = input[key] as? Int { return Double(i) }
            if let s = input[key] as? String { return Double(s) }
            return nil
        }
        let pace = number("pace_percent").flatMap { $0 > 0 && $0 <= 1.5 ? $0 : nil }
        let breaks = number("diet_break_every_weeks").flatMap { $0 >= 0 && $0 <= 12 ? Int($0) : nil }
        let shift = number("day_shift_percent").flatMap { $0 >= 0 && $0 <= 25 ? $0 / 100 : nil }
        return DietPlanChange(goal: (input["goal"] as? String).flatMap(DietPlan.Goal.init(rawValue:)),
                              pacePercent: pace, form: (input["form"] as? String).flatMap(DietForm.init(rawValue:)),
                              dietBreakEveryWeeks: breaks, dayShift: shift,
                              breakWeekNow: input["break_week_now"] as? Bool,
                              rationale: ((input["rationale"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              createdAt: now)
    }

    /// The plan with the change made. A new goal starts the plan again from today; dials the simple mode does
    /// not have switch the plan to the advanced mode, as the planner would.
    public func apply(to plan: DietPlan, today: String, weightKg: Double) -> DietPlan {
        var next = plan
        if let goal, goal != plan.goal {
            next.goal = goal
            next.startDay = today
            next.startWeightKg = weightKg
            next.adjustmentKcal = 0
            if goal == .recomp || goal == .maintain { next.goalWeightKg = nil }
            if goal == .gain || goal == .recomp { next.strength = true }
        }
        if let pacePercent { next.pacePercent = pacePercent }
        if let form { next.form = form; if let addon = next.addon, !addon.fits(form) { next.addon = nil } }
        if let dietBreakEveryWeeks { next.mode = .advanced; next.dietBreakEveryWeeks = dietBreakEveryWeeks == 0 ? nil : dietBreakEveryWeeks }
        if let dayShift { next.mode = .advanced; next.dayShift = dayShift }
        if breakWeekNow == true { next.breakFromDay = today }
        if pacePercent.map({ $0 > DietPlan.paceLimit(goal: next.goal, mode: .simple) }) == true { next.mode = .advanced }
        return next
    }

    public func encoded() -> String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }
    public static func decode(_ raw: String?) -> DietPlanChange? {
        raw.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(DietPlanChange.self, from: $0) }
    }
}
