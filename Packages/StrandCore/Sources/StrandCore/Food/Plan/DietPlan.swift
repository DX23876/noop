import Foundation

/// The wearer's diet plan (decision 2026-11-09): what they chose in the planner, stored as JSON under one key on
/// both platforms. Every number a screen shows is worked out from it by `DietTargets`; nothing derived is stored.
public struct DietPlan: Codable, Equatable, Sendable {
    /// `recomp`: body recomposition (owner, 2026-11-10), losing fat while building muscle at about the usual burn,
    /// with strength training and plenty of protein.
    public enum Goal: String, Codable, CaseIterable, Sendable { case lose, maintain, gain, recomp }
    /// How long the wearer has trained for strength; it says how well recomposition fits.
    public enum Experience: String, Codable, CaseIterable, Sendable { case new, returning, someYears, manyYears }
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
            case (.maintain, _), (.recomp, _): 0
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
    /// Active days bring more calories (owner, 2026-11-10): part of what the strap measured above the usual
    /// burn is added to the day's goal (`DietActiveDay`). Nil or false is off; optional so older plans decode.
    public var activeDays: Bool?
    /// What the plan's usual burn comes from: the strap's measurement, or the real burn worked out from completely
    /// logged days and the weight trend (`DietExpenditure`). Nil is the strap.
    public var burnSource: BurnSource?

    public enum BurnSource: String, Codable, CaseIterable, Sendable { case strap, scale }
    /// Recomposition, advanced: the deficit in percent of the burn (0 to 15); nil is the simple mode's 5 %.
    public var recompDeficitPercent: Double?
    /// Weekdays the wearer plans to train strength (1 Sunday … 7 Saturday, as `Calendar` counts them).
    public var trainingWeekdays: [Int]?
    /// Share of the day's calories moved from rest days to training days (0 to 0.25); nil or 0 is even days.
    /// Recomposition always shifts; the other goals only in the advanced mode.
    public var dayShift: Double?
    public var experience: Experience?
    /// A diet break the wearer took on Forge's suggestion: a week at maintenance from this day.
    public var breakFromDay: String?

    /// The share of the calories that moves to training days, as the plan has it: recomposition 10 % unless set.
    public var effectiveDayShift: Double {
        if form.fasting != nil { return 0 }
        let program = DietProgram.defaultDayShift(goal)
        return (mode == .advanced || goal == .recomp ? (dayShift ?? program) : program).clamped(0, 0.25)
    }

    public init(goal: Goal = .lose, mode: Mode = .simple, pacePercent: Double = 0.5, form: DietForm = .balanced,
                addon: DietAddon? = nil, strength: Bool = false, goalWeightKg: Double? = nil, steering: Steering = .coached,
                proteinPerKg: Double? = nil, carbShareOfRest: Double? = nil, fixedKcal: Double? = nil,
                dietBreakEveryWeeks: Int? = nil, keep: [Keep] = [], startDay: String, startWeightKg: Double,
                adjustmentKcal: Double = 0, lastAdjustedDay: String? = nil, hideNumbers: Bool = false,
                pregnantOrNursing: Bool = false, activeDays: Bool? = nil, burnSource: BurnSource? = nil) {
        self.activeDays = activeDays; self.burnSource = burnSource
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
        case .maintain, .recomp: 0
        }
    }

    /// Recomposition's deficit in percent of the burn: 5 in the simple mode, the wearer's 0 to 15 in the advanced one.
    public var recompDeficit: Double {
        mode == .advanced ? (recompDeficitPercent ?? 5).clamped(0, 15) : 5
    }
}

/// Who the planner is for: the facts it needs from the profile.
public struct DietPerson: Equatable, Sendable {
    public var weightKg: Double
    public var heightCm: Double?
    public var age: Int?
    public var male: Bool?
    /// The latest body fat measurement in percent (Apple Health, Health Connect or the tape method), when known.
    public var bodyFatPercent: Double?

    public init(weightKg: Double, heightCm: Double?, age: Int?, male: Bool?, bodyFatPercent: Double? = nil) {
        self.weightKg = weightKg; self.heightCm = heightCm; self.age = age; self.male = male
        self.bodyFatPercent = bodyFatPercent
    }

    /// Weight without fat, when the body fat share is known and plausible (3 to 60 %).
    public var leanMassKg: Double? {
        guard let bf = bodyFatPercent, bf >= 3, bf <= 60 else { return nil }
        return weightKg * (1 - bf / 100)
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
