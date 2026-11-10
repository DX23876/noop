import Foundation
import StrandAnalytics

/// The day's food goals, resolved once for every screen that shows them (Food on iOS and Android, Today's
/// energy card, the coach), so two readouts of the goal can never disagree.
public enum FoodTargets {
    /// Where the calorie goal comes from, said on the screen in words.
    public enum CalorieBasis: String, Sendable, Codable { case measured, formula, fixed, plan }

    public struct Calories: Equatable, Sendable, Codable {
        /// What to eat today to follow the wearer's own plan.
        public var kcal: Double
        /// The usual burn the goal starts from.
        public var burnKcal: Double
        /// The plan's daily deficit (negative) or surplus (positive); zero when the wearer holds weight.
        public var planDeltaKcal: Double
        public var basis: CalorieBasis
        /// The part of `kcal` an active day added (`DietActiveDay`); nil or zero on an ordinary day.
        public var activeBonusKcal: Double?
    }

    /// The calorie goal: the measured usual burn of the last weeks (strap and Health), else the formula's,
    /// plus the plan's daily change. Nil without either burn figure. Never below the basal rate's floor of
    /// 1,200 kcal: the screen is not a place to suggest a crash diet.
    public static func calories(measuredMeanKcal: Double?, allDaysMeanKcal: Double?, formulaTdeeKcal: Double?,
                                dailyDeltaKcal: Double?) -> Calories? {
        let measured = measuredMeanKcal ?? allDaysMeanKcal
        guard let burn = measured ?? formulaTdeeKcal, burn.isFinite, burn > 0 else { return nil }
        let delta = dailyDeltaKcal.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return Calories(kcal: max(minimumKcal, burn + delta), burnKcal: burn, planDeltaKcal: delta,
                        basis: measured != nil ? .measured : .formula)
    }

    /// The lowest goal shown, whatever the plan says.
    public static let minimumKcal: Double = 1_200
}

extension FoodTargets {
    /// The wearer's goal settings, the same keys on both platforms (UserDefaults on Apple, NoopPrefs on Android).
    public enum Keys {
        /// A fixed calorie goal in kcal; 0 or absent follows the energy plan.
        public static let calories = "food.goal.kcal"
        /// Shares of the calorie goal, in percent.
        public static let proteinPercent = "food.goal.proteinPercent"
        public static let carbsPercent = "food.goal.carbsPercent"
        public static let fatPercent = "food.goal.fatPercent"
        /// Up to four nutrients shown on the Food page, comma-separated raw values.
        public static let pinned = "food.pinnedNutrients"
    }

    /// Default split: inside the acceptable ranges of the Institute of Medicine (protein 10 to 35, carbohydrate
    /// 45 to 65, fat 20 to 35 % of energy), with protein in the upper half of its range for people who train.
    public static let defaultSplit = (protein: 25.0, carbs: 45.0, fat: 30.0)
    public static let defaultPinned: [FoodNutrient] = [.fiberG, .epaG, .satFatG, .saltG]

    public struct Macros: Equatable, Sendable, Codable {
        public var proteinG: Double, carbsG: Double, fatG: Double
    }

    /// Grams of each macronutrient for `kcal` at the given shares (4, 4 and 9 kcal per gram). Shares that do not
    /// add to 100 are scaled so they do.
    public static func macros(kcal: Double, protein: Double, carbs: Double, fat: Double) -> Macros? {
        let total = protein + carbs + fat
        guard kcal > 0, total > 0, [protein, carbs, fat].allSatisfy({ $0 >= 0 }) else { return nil }
        return Macros(proteinG: kcal * protein / total / 4, carbsG: kcal * carbs / total / 4, fatG: kcal * fat / total / 9)
    }

    /// The calorie goal, the wearer's fixed one when set, otherwise the plan's.
    public static func calories(fixedKcal: Double?, plan: Calories?) -> Calories? {
        guard let fixedKcal, fixedKcal >= 800, fixedKcal <= 10_000 else { return plan }
        return Calories(kcal: fixedKcal, burnKcal: plan?.burnKcal ?? fixedKcal, planDeltaKcal: 0, basis: .fixed)
    }

    /// The calorie goal for `day` from the wearer's diet plan (decision 2026-11-09), which outranks the older fixed
    /// goal and the energy plan's rate. On a fasting form's fasting day it is that day's own figure.
    /// `activeBonusKcal` is the day's extra from `DietActiveDay`, added on top.
    /// `strengthDays` are the days with logged strength training, for the plan's training-day shift.
    public static func calories(plan: DietPlan, result: DietTargets.Result, day: String,
                                activeBonusKcal: Double = 0, strengthDays: Set<String> = []) -> Calories {
        let bonus = max(0, activeBonusKcal)
        return Calories(kcal: DietTargets.kcal(on: day, plan: plan, result: result, strengthDays: strengthDays) + bonus,
                        burnKcal: result.burnKcal,
                        planDeltaKcal: result.averageKcal - result.burnKcal, basis: .plan,
                        activeBonusKcal: bonus > 0 ? bonus : nil)
    }

    /// Macro goals from the diet plan; on a fasting day scaled to that day's calories.
    /// An active day's extra goes to carbohydrate alone: protein and fat stay what the plan set.
    /// The training-day shift goes the same way: carbohydrate moves, protein and fat stay.
    public static func macros(plan: DietPlan, result: DietTargets.Result, day: String,
                              activeBonusKcal: Double = 0, strengthDays: Set<String> = []) -> Macros {
        var macros = planMacros(plan: plan, result: result, day: day)
        let shift = DietTargets.shiftKcal(on: day, plan: plan, result: result, strengthDays: strengthDays)
        macros.carbsG = max(0, macros.carbsG + (max(0, activeBonusKcal) + shift) / 4)
        return macros
    }

    static func planMacros(plan: DietPlan, result: DietTargets.Result, day: String) -> Macros {
        // The day before any training-day shift, which `macros` adds as carbohydrate alone.
        let kcal = DietTargets.kcal(on: day, plan: plan, result: result) - DietTargets.shiftKcal(on: day, plan: plan, result: result)
        let scale = result.averageKcal > 0 ? kcal / result.averageKcal : 1
        // Protein holds on eating days (it protects muscle); carbohydrate and fat take the difference.
        let fasting = DietTargets.isFastingDay(day, plan: plan)
        let protein = fasting ? result.proteinG * scale : result.proteinG
        let rest = max(0, kcal - protein * 4)
        let restPlanned = max(1, result.carbsG * 4 + result.fatG * 9)
        return Macros(proteinG: protein, carbsG: rest * (result.carbsG * 4 / restPlanned) / 4,
                      fatG: rest * (result.fatG * 9 / restPlanned) / 9)
    }

    public static func pinned(from raw: String?) -> [FoodNutrient] {
        let parsed = (raw ?? "").split(separator: ",").compactMap { FoodNutrient(rawValue: String($0)) }
        return parsed.isEmpty ? defaultPinned : Array(parsed.prefix(4))
    }
}
