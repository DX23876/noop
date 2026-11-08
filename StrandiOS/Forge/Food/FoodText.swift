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
        let unit = switch n.unit { case .kcal: "kcal"; case .g: "g"; case .mg: "mg"; case .ug: "µg" }
        let digits = value < 1 ? 2 : value < 10 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(0...digits)).locale(AppLanguage.activeLocale)) + " " + unit
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
        case .epaG: String(localized: "Omega-3 from fish (EPA and DHA)")
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
}
#endif
