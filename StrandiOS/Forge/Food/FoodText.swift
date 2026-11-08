#if os(iOS)
import Foundation
import StrandCore
import StrandAnalytics

/// How the Food screens write numbers, meals and nutrient names, in one place.
enum FoodText {
    static func kcal(_ value: Double?) -> String {
        guard let value else { return "–" }
        return Int(value.rounded()).formatted(.number.locale(AppLanguage.activeLocale))
    }

    static func grams(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value.formatted(.number.precision(.fractionLength(0...(value < 10 ? 1 : 0))).locale(AppLanguage.activeLocale))
    }

    static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.activeLocale))
    }

    static func meal(_ kind: FoodLog.MealKind) -> String {
        switch kind {
        case .breakfast: String(localized: "Breakfast")
        case .lunch: String(localized: "Lunch")
        case .dinner: String(localized: "Dinner")
        case .snack: String(localized: "Snack")
        }
    }

    static func amount(_ value: Double, _ n: FoodNutrient) -> String {
        // Omega-3 from fish is stored in grams but read in milligrams ("80 mg of 250 mg", not "0.08 g").
        if n == .epaG || n == .dhaG {
            return Int((value * 1_000).rounded()).formatted(.number.locale(AppLanguage.activeLocale)) + " mg"
        }
        let unit = switch n.unit { case .kcal: "kcal"; case .g: "g"; case .mg: "mg"; case .ug: "µg" }
        let digits = value < 1 ? 2 : value < 10 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(0...digits)).locale(AppLanguage.activeLocale)) + " " + unit
    }

    /// A recommendation as the page states it: the amount and its direction, without who recommends it (that is
    /// behind the page's info button).
    static func recommendation(_ reference: FoodReference.Value, _ n: FoodNutrient) -> String {
        let value = amount(reference.amount, n)
        return reference.kind == .atLeast ? String(localized: "Recommended: at least \(value) a day")
                                          : String(localized: "Recommended: under \(value) a day")
    }

    static func group(_ group: String) -> String {
        switch group {
        case "minerals": String(localized: "Minerals")
        case "vitamins": String(localized: "Vitamins")
        default: String(localized: "Fats, fibre and protein")
        }
    }

    static func nutrient(_ n: FoodNutrient) -> String {
        switch n {
        case .energyKcal: String(localized: "Energy")
        case .proteinG: String(localized: "Protein")
        case .carbsG: String(localized: "Carbs")
        case .fatG: String(localized: "Fat")
        case .fiberG: String(localized: "Fibre")
        case .sugarG: String(localized: "Sugar")
        case .satFatG: String(localized: "Saturated fat")
        case .monoFatG: String(localized: "Monounsaturated fat")
        case .polyFatG: String(localized: "Polyunsaturated fat")
        case .omega3G: String(localized: "Omega-3, total")
        case .epaG: String(localized: "Omega-3")
        case .dhaG: String(localized: "DHA")
        case .alcoholG: String(localized: "Alcohol")
        case .waterG: String(localized: "Water")
        case .cholesterolMg: String(localized: "Cholesterol")
        case .saltG: String(localized: "Salt")
        case .sodiumMg: String(localized: "Sodium")
        case .potassiumMg: String(localized: "Potassium")
        case .calciumMg: String(localized: "Calcium")
        case .magnesiumMg: String(localized: "Magnesium")
        case .phosphorusMg: String(localized: "Phosphorus")
        case .ironMg: String(localized: "Iron")
        case .zincMg: String(localized: "Zinc")
        case .iodineUg: String(localized: "Iodine")
        case .copperMg: String(localized: "Copper")
        case .manganeseMg: String(localized: "Manganese")
        case .vitaminAUg: String(localized: "Vitamin A")
        case .vitaminDUg: String(localized: "Vitamin D")
        case .vitaminEMg: String(localized: "Vitamin E")
        case .vitaminKUg: String(localized: "Vitamin K")
        case .thiaminMg: String(localized: "Vitamin B1")
        case .riboflavinMg: String(localized: "Vitamin B2")
        case .niacinMg: String(localized: "Niacin")
        case .vitaminB6Mg: String(localized: "Vitamin B6")
        case .folateUg: String(localized: "Folate")
        case .vitaminB12Ug: String(localized: "Vitamin B12")
        case .vitaminCMg: String(localized: "Vitamin C")
        case .pantothenicMg: String(localized: "Pantothenic acid")
        case .biotinUg: String(localized: "Biotin")
        }
    }

    /// Where an item's estimated values came from, in words; nil when nothing is estimated.
    static func estimateNote(_ item: FoodItem) -> String? {
        guard let from = item.estimatedFrom, let count = item.estimatedKeys?.count, count > 0 else { return nil }
        if from == FoodEstimate.aiSource {
            return String(localized: "\(count) vitamins and minerals are your coach's estimate. No similar food in the German Nutrient Database was close enough. Treat them as rough.")
        }
        return String(localized: "\(count) vitamins and minerals are taken from a similar food in the German Nutrient Database.")
    }

    // MARK: Evening sentence and score

    /// One short sentence per observation, the good one first ("Plenty of protein. Salt on the high side.").
    static func sentence(_ points: [FoodDaySentence.Point]) -> String {
        points.map(phrase).joined(separator: " ")
    }

    private static func phrase(_ p: FoodDaySentence.Point) -> String {
        switch (p.nutrient, p.plenty) {
        case (.proteinG, true): String(localized: "Plenty of protein.")
        case (.proteinG, false): String(localized: "Protein on the low side.")
        case (.fiberG, true): String(localized: "Plenty of fibre.")
        case (.fiberG, false): String(localized: "Fibre on the low side.")
        case (.satFatG, _): String(localized: "Quite a lot of saturated fat.")
        case (.sugarG, _): String(localized: "Quite a lot of sugar.")
        case (.saltG, _): String(localized: "Salt on the high side.")
        default: ""
        }
    }

    static func component(_ c: FoodScore.Component) -> String {
        switch c {
        case .vegetables: String(localized: "Vegetables")
        case .fruit: String(localized: "Fruit")
        case .wholeGrains: String(localized: "Whole grains")
        case .sugaryDrinks: String(localized: "Sweet drinks and juice")
        case .nutsLegumes: String(localized: "Nuts and pulses")
        case .redMeat: String(localized: "Red and processed meat")
        case .fishOmega3: String(localized: "Omega-3")
        case .polyFats: String(localized: "Fats from plant oils and nuts")
        case .sodium: String(localized: "Salt")
        case .alcohol: String(localized: "Alcohol")
        }
    }

    /// What earns the full points, in everyday words.
    static func componentGoal(_ c: FoodScore.Component, male: Bool) -> String {
        switch c {
        case .vegetables: String(localized: "Full points from 5 portions a day")
        case .fruit: String(localized: "Full points from 4 portions a day")
        case .wholeGrains: male ? String(localized: "Full points from 90 g a day") : String(localized: "Full points from 75 g a day")
        case .sugaryDrinks: String(localized: "Full points with none")
        case .nutsLegumes: String(localized: "Full points from 1 portion a day")
        case .redMeat: String(localized: "Full points with none")
        case .fishOmega3: String(localized: "Full points from about two fish meals a week")
        case .polyFats: String(localized: "Full points from a tenth of your calories")
        case .sodium: String(localized: "Full points up to about 4 g salt a day")
        case .alcohol: String(localized: "Full points with none")
        }
    }

    /// The week's daily amount in the component's everyday unit.
    static func componentAmount(_ part: FoodScore.Part) -> String {
        let a = part.amountPerDay
        func one(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1)).locale(AppLanguage.activeLocale)) }
        switch part.component {
        case .vegetables, .fruit, .sugaryDrinks, .nutsLegumes, .redMeat:
            return String(localized: "\(one(a)) portions a day")
        case .wholeGrains: return String(localized: "\(grams(a)) g a day")
        case .fishOmega3: return String(localized: "\(kcal(a)) mg a day")
        case .polyFats: return String(localized: "\(one(a)) % of calories")
        case .sodium: return String(localized: "\(one(a * 2.5 / 1_000)) g salt a day")
        case .alcohol: return String(localized: "\(one(a)) drinks a day")
        }
    }

    /// The score in words, so the number is never the only reading.
    static func scoreWord(_ score: Double) -> String {
        switch score {
        case ..<40: String(localized: "Room to grow")
        case ..<60: String(localized: "Fair")
        case ..<75: String(localized: "Good")
        default: String(localized: "Very good")
        }
    }
}
#endif
