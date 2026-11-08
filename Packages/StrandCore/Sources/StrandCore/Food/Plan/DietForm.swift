import Foundation

/// The ways of eating the diet planner offers (decision 2026-11-09). Each brings its share of carbohydrate and fat
/// after protein, the foods that suit it and those it keeps rare, and how hard it is to live with: effort describes
/// keeping it up in everyday life, not how well it works. At the same calories and enough protein, people lose
/// about the same on all of them; the one you keep is the one that works.
public enum DietForm: String, CaseIterable, Sendable, Codable {
    case balanced, mediterranean, dash, highProtein, flexitarian, lowFat, lowCarb, keto
    case fasting168, fasting52, alternateDay, alternateDayFull

    /// 1 (easy to live with) to 5 (very hard).
    public var effort: Int {
        switch self {
        case .balanced: 1
        case .mediterranean, .dash, .highProtein, .flexitarian: 2
        case .lowFat, .lowCarb, .fasting168: 3
        case .fasting52, .alternateDay: 4
        case .keto, .alternateDayFull: 5
        }
    }

    /// Only in the advanced mode: forms with whole fasting days or very strict rules.
    public var advancedOnly: Bool { [.keto, .fasting52, .alternateDay, .alternateDayFull].contains(self) }

    /// Fasting days a week on average and how much of the usual burn such a day allows.
    public var fasting: (daysPerWeek: Double, share: Double)? {
        switch self {
        case .fasting52: (2, 0.25)
        case .alternateDay: (3.5, 0.25)
        case .alternateDayFull: (3.5, 0)
        default: nil
        }
    }

    /// Daily carbohydrate cap in grams, for the forms that are defined by it.
    public var carbCapG: Double? {
        switch self {
        case .lowCarb: 120
        case .keto: 25
        default: nil
        }
    }

    /// Carbohydrate's share of the energy left after protein, for the forms without a cap.
    public var carbShareOfRest: Double {
        switch self {
        case .mediterranean: 0.5
        case .lowFat: 0.7
        case .dash: 0.6
        default: 0.55
        }
    }

    /// Extra protein per kilogram of reference weight on top of the goal's own.
    public var proteinBonusPerKg: Double { self == .highProtein ? 0.4 : 0 }

    public var suits: [FoodGroupMotif] {
        switch self {
        case .balanced, .fasting168, .fasting52, .alternateDay, .alternateDayFull: [.vegetables, .fruit, .grains, .legumes, .fish]
        case .mediterranean: [.vegetables, .legumes, .fish, .fats, .fruit]
        case .dash: [.vegetables, .fruit, .dairy, .legumes, .grains]
        case .highProtein: [.poultry, .fish, .eggs, .dairy, .legumes]
        case .flexitarian: [.vegetables, .legumes, .grains, .fruit, .fish]
        case .lowFat: [.vegetables, .fruit, .grains, .fish, .poultry]
        case .lowCarb: [.vegetables, .eggs, .fish, .poultry, .dairy]
        case .keto: [.eggs, .fish, .fats, .dairy, .vegetables]
        }
    }

    public var keepsRare: [FoodGroupMotif] {
        switch self {
        case .balanced, .fasting168, .fasting52, .alternateDay, .alternateDayFull: [.sweets, .drinks]
        case .mediterranean: [.meat, .sweets]
        case .dash: [.meat, .sweets, .dishes]
        case .highProtein: [.sweets, .drinks]
        case .flexitarian: [.meat, .sweets]
        case .lowFat: [.fats, .sweets, .meat]
        case .lowCarb: [.bread, .grains, .sweets, .drinks]
        case .keto: [.bread, .grains, .fruit, .sweets, .drinks]
        }
    }

    /// Typical shares of energy (protein, carbohydrate, fat), for comparing a logged week with each form.
    var typicalSplit: (protein: Double, carbs: Double, fat: Double) {
        switch self {
        case .highProtein: (0.32, 0.38, 0.30)
        case .lowFat: (0.22, 0.58, 0.20)
        case .lowCarb: (0.28, 0.20, 0.52)
        case .keto: (0.22, 0.05, 0.73)
        case .mediterranean: (0.18, 0.42, 0.40)
        case .dash: (0.20, 0.52, 0.28)
        default: (0.20, 0.48, 0.32)
        }
    }
}

/// A way of eating that can sit on top of any form: what is left out.
public enum DietAddon: String, CaseIterable, Sendable, Codable {
    case vegetarian, vegan, pescatarian

    /// Added to the form's effort.
    public var effort: Double {
        switch self {
        case .pescatarian: 0.5
        case .vegetarian: 0.5
        case .vegan: 1.5
        }
    }

    public var leavesOut: [FoodGroupMotif] {
        switch self {
        case .pescatarian: [.meat, .poultry]
        case .vegetarian: [.meat, .poultry, .fish]
        case .vegan: [.meat, .poultry, .fish, .dairy, .eggs]
        }
    }

    /// Keto leaves almost nothing on a vegan plate; the planner does not offer the pair.
    public func fits(_ form: DietForm) -> Bool { !(self == .vegan && form == .keto) }
}

extension DietForm {
    /// Whether a food group suits this form (and addon): +1 suits, -1 kept rare or left out, 0 neutral.
    public func fit(_ group: FoodGroupMotif, addon: DietAddon?) -> Int {
        if let addon, addon.leavesOut.contains(group) { return -1 }
        if keepsRare.contains(group) { return -1 }
        return suits.contains(group) ? 1 : 0
    }
}
