import Foundation

/// What digesting food costs, the thermic effect of food (owner decision 2026-11-27, open point 4 of the
/// everyday plan). Doubly-labelled-water measurements contain it, the strap model does not: about a tenth of
/// the day on a mixed diet (Westerterp 2004, Nutr Metab 1:5), more with protein, almost nothing with fat.
///
/// A day the wearer marked as completely logged prices its own food: protein 25 %, carbohydrate 7.5 %, fat
/// 2 % of their energy, anything else (alcohol, fibre, rounding) 10 %. Every other day takes the standard
/// tenth of the whole day, a ninth of everything else, because a half-logged day would price only the half.
/// It is part of the everyday share, like the cost of sitting and standing, and never part of active energy.
public enum Digestion {
    /// A tenth of the whole day is a ninth of the rest of it.
    public static let standardShareOfRest = 1.0 / 9.0
    public static let proteinShare = 0.25
    public static let carbShare = 0.075
    public static let fatShare = 0.02
    public static let otherShare = 0.10

    /// What digesting a completely logged day costs, from its energy and macronutrients. Nil without anything
    /// eaten; a day of only water and black coffee costs nothing.
    public static func kcal(caloriesKcal: Double?, proteinG: Double?, carbsG: Double?, fatG: Double?) -> Double? {
        func grams(_ value: Double?) -> Double { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0 }
        let protein = grams(proteinG) * 4, carbs = grams(carbsG) * 4, fat = grams(fatG) * 9
        let macros = protein + carbs + fat
        let calories = caloriesKcal.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard let total = calories ?? (macros > 0 ? macros : nil) else { return nil }
        guard macros > 0 else { return total * otherShare }
        let other = max(0, total - macros)
        return protein * proteinShare + carbs * carbShare + fat * fatShare + other * otherShare
    }
}
