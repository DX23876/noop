import Foundation

/// The wearer's diet plan (decision 2026-11-09): what they chose in the planner, stored as JSON under one key on
/// both platforms. Every number a screen shows is worked out from it by `DietTargets`; nothing derived is stored.
public struct DietPlan: Codable, Equatable, Sendable {
    public enum Goal: String, Codable, CaseIterable, Sendable { case lose, maintain, gain }
    public enum Mode: String, Codable, CaseIterable, Sendable { case simple, advanced }
    /// How much Forge steers: everything, the calories only (macros stay the wearer's), or nothing.
    public enum Steering: String, Codable, CaseIterable, Sendable { case coached, caloriesOnly, manual }
    /// The simple mode's three paces, in percent of body weight a week.
    public enum Pace: String, Codable, CaseIterable, Sendable {
        case gentle, normal, ambitious
        public func percent(for goal: Goal) -> Double {
            switch (goal, self) {
            case (.lose, .gentle): 0.5
            case (.lose, .normal): 0.75
            case (.lose, .ambitious): 1.0
            case (.gain, .gentle): 0.25
            case (.gain, _): 0.5
            case (.maintain, _): 0
            }
        }
    }
    /// What the wearer would not give up, asked so the suggested forms fit their life.
    public enum Keep: String, Codable, CaseIterable, Sendable { case breadAndPasta, meat, sweets, lateEating, regularMeals }

    public var goal: Goal
    public var mode: Mode
    /// Percent of body weight a week, always positive; the goal says the direction.
    public var pacePercent: Double
    public var form: DietForm
    public var addon: DietAddon?
    public var strength: Bool
    public var goalWeightKg: Double?
    public var steering: Steering
    /// Advanced: grams of protein per kilogram of reference weight, replacing the goal's own.
    public var proteinPerKg: Double?
    /// Advanced: carbohydrate's share of the energy after protein, replacing the form's.
    public var carbShareOfRest: Double?
    /// Manual steering: the wearer's own daily calories.
    public var fixedKcal: Double?
    /// Advanced: a week at maintenance after this many weeks in a deficit; nil for none.
    public var dietBreakEveryWeeks: Int?
    public var keep: [Keep]
    public var startDay: String
    public var startWeightKg: Double
    /// Sum of the weekly adjustments Forge made to the calories, positive or negative.
    public var adjustmentKcal: Double
    public var lastAdjustedDay: String?
    /// The wearer asked Forge to hide weight and numbers (a gentler view, for anyone who wants it).
    public var hideNumbers: Bool
    public var pregnantOrNursing: Bool

    public init(goal: Goal = .lose, mode: Mode = .simple, pacePercent: Double = 0.5, form: DietForm = .balanced,
                addon: DietAddon? = nil, strength: Bool = false, goalWeightKg: Double? = nil, steering: Steering = .coached,
                proteinPerKg: Double? = nil, carbShareOfRest: Double? = nil, fixedKcal: Double? = nil,
                dietBreakEveryWeeks: Int? = nil, keep: [Keep] = [], startDay: String, startWeightKg: Double,
                adjustmentKcal: Double = 0, lastAdjustedDay: String? = nil, hideNumbers: Bool = false,
                pregnantOrNursing: Bool = false) {
        self.goal = goal; self.mode = mode; self.pacePercent = pacePercent; self.form = form; self.addon = addon
        self.strength = strength; self.goalWeightKg = goalWeightKg; self.steering = steering
        self.proteinPerKg = proteinPerKg; self.carbShareOfRest = carbShareOfRest; self.fixedKcal = fixedKcal
        self.dietBreakEveryWeeks = dietBreakEveryWeeks; self.keep = keep; self.startDay = startDay
        self.startWeightKg = startWeightKg; self.adjustmentKcal = adjustmentKcal; self.lastAdjustedDay = lastAdjustedDay
        self.hideNumbers = hideNumbers; self.pregnantOrNursing = pregnantOrNursing
    }

    /// The preference key, the same on Apple (UserDefaults) and Android (NoopPrefs).
    public static let storageKey = "food.plan"

    public func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(_ raw: String?) -> DietPlan? {
        guard let data = raw?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DietPlan.self, from: data)
    }

    /// The pace the mode allows: up to 1 % a week in the simple mode, 1.5 % in the advanced one; gaining up to 0.5
    /// and 1 %.
    public static func paceLimit(goal: Goal, mode: Mode) -> Double {
        switch goal {
        case .lose: mode == .simple ? 1.0 : 1.5
        case .gain: mode == .simple ? 0.5 : 1.0
        case .maintain: 0
        }
    }
}

/// Who the planner is for: the facts it needs from the profile.
public struct DietPerson: Equatable, Sendable {
    public var weightKg: Double
    public var heightCm: Double?
    public var age: Int?
    public var male: Bool?

    public init(weightKg: Double, heightCm: Double?, age: Int?, male: Bool?) {
        self.weightKg = weightKg; self.heightCm = heightCm; self.age = age; self.male = male
    }

    public var bmi: Double? {
        guard let h = heightCm, h > 0 else { return nil }
        return weightKg / pow(h / 100, 2)
    }

    /// The weight protein is reckoned on: at a high BMI the weight at BMI 25, so a large body is not asked for an
    /// impossible amount; otherwise the real weight.
    public var referenceWeightKg: Double {
        guard let h = heightCm, h > 0, let bmi, bmi > 30 else { return weightKg }
        return 25 * pow(h / 100, 2)
    }

    /// The lowest goal weight the planner accepts: BMI 18.5.
    public var lowestGoalWeightKg: Double? { heightCm.map { 18.5 * pow($0 / 100, 2) } }
}
