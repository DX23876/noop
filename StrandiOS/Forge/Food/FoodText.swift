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

    /// The plan's phase of a day, on the plate.
    static func phase(_ p: DietProgram.Phase) -> String {
        switch p {
        case .main: ""
        case .dietBreak: String(localized: "Break week: eat what you burn")
        case .transition: String(localized: "Goal reached: stepping down to holding")
        case .holding: String(localized: "Holding your goal weight")
        }
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

    /// Where a product's values come from, in words. One wording for every screen that names a source.
    static func sourceNote(_ item: FoodItem) -> String {
        switch item.source {
        case .bls: String(localized: "Source: German Nutrient Database (BLS 4.0), Max Rubner-Institut, CC BY 4.0.")
        case .off, .online: String(localized: "Source: Open Food Facts, ODbL. Values are entered by volunteers and can be wrong.")
        case .own: String(localized: "Your own food.")
        case .recipe: String(localized: "Your recipe, per 100 g of the whole dish.")
        }
    }

    /// Where an item's estimated values came from, in words; nil when nothing is estimated.
    static func estimateNote(_ item: FoodItem) -> String? {
        // A computed energy value carries its own mark and its own line on the screen; it is not a borrowed nutrient.
        let count = (item.estimatedKeys ?? []).filter { !$0.hasPrefix(FoodEnergy.markPrefix) }.count
        guard let from = item.estimatedFrom, count > 0 else { return nil }
        if from == FoodEstimate.aiSource {
            return String(localized: "\(count) vitamins and minerals are your coach's estimate. No similar food in the German Nutrient Database was close enough. Treat them as rough.")
        }
        return String(localized: "\(count) vitamins and minerals are taken from a similar food in the German Nutrient Database.")
    }

    /// A food group's everyday name, under its picture.
    static func motif(_ m: FoodGroupMotif) -> String {
        switch m {
        case .bread: String(localized: "Bread")
        case .grains: String(localized: "Grains")
        case .fruit: String(localized: "Fruit")
        case .vegetables: String(localized: "Vegetables")
        case .legumes: String(localized: "Pulses and nuts")
        case .dairy: String(localized: "Dairy")
        case .eggs: String(localized: "Eggs")
        case .fish: String(localized: "Fish")
        case .meat: String(localized: "Red meat")
        case .poultry: String(localized: "Poultry")
        case .sweets: String(localized: "Sweets")
        case .drinks: String(localized: "Sweet drinks")
        case .fats: String(localized: "Oils and fats")
        case .dishes: String(localized: "Ready meals")
        }
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
        case .nutsLegumes: String(localized: "Nuts and pulses")
        case .redMeat: String(localized: "Red meat")
        case .processedMeat: String(localized: "Sausage and cured meat")
        case .fishOmega3: String(localized: "Omega-3")
        // It counts the sugar of juice and honey too, the WHO's free sugar, so the name says juice.
        case .freeSugar: String(localized: "Added sugar and juice")
        case .satFat: String(localized: "Saturated fat")
        case .sodium: String(localized: "Salt")
        case .alcohol: String(localized: "Alcohol")
        case .fiber: String(localized: "Fibre")
        }
    }

    /// What earns the full points, in everyday words.
    static func componentGoal(_ c: FoodScore.Component, male: Bool) -> String {
        switch c {
        case .vegetables: String(localized: "Full points from 5 portions a day")
        case .fruit: String(localized: "Full points from 4 portions a day")
        case .wholeGrains: male ? String(localized: "Full points from 90 g a day") : String(localized: "Full points from 75 g a day")
        case .nutsLegumes: String(localized: "Full points from 1 portion a day")
        case .redMeat: String(localized: "Nothing off up to 350 g a week")
        case .processedMeat: String(localized: "Nothing off without sausage and cured meat")
        case .fishOmega3: String(localized: "Full points from about two fish meals a week")
        case .freeSugar: String(localized: "Nothing off up to a twentieth of your calories")
        case .satFat: String(localized: "Nothing off up to a tenth of your calories")
        case .sodium: String(localized: "Nothing off up to about 4 g salt a day")
        case .alcohol: String(localized: "Full points with none")
        case .fiber: String(localized: "Full points from 30 g a day")
        }
    }

    /// The week's daily amount in the component's everyday unit.
    static func componentAmount(_ part: FoodScore.Part) -> String {
        let a = part.amountPerDay
        func one(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1)).locale(AppLanguage.activeLocale)) }
        switch part.component {
        case .vegetables, .fruit, .nutsLegumes, .processedMeat:
            return String(localized: "\(one(a)) portions a day")
        case .wholeGrains, .fiber, .redMeat: return String(localized: "\(grams(a)) g a day")
        case .fishOmega3: return String(localized: "\(kcal(a)) mg a day")
        case .freeSugar, .satFat: return String(localized: "\(one(a)) % of calories")
        case .sodium: return String(localized: "\(one(a * 2.5 / 1_000)) g salt a day")
        case .alcohol: return String(localized: "\(one(a)) drinks a day")
        }
    }

    /// A note from 0 to 10 with one decimal ("7.8"), in the app language.
    static func note(_ score: Double) -> String {
        score.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.activeLocale))
    }

    /// A note in words, on the 0 to 10 scale.
    static func noteWord(_ score: Double) -> String { scoreWord(score * 10) }

    /// A stable key for a badge, for "already celebrated".
    static func badgeKey(_ badge: FoodBadges.Badge) -> String {
        switch badge {
        case .firstFullWeek: "firstFullWeek"
        case .days30: "days30"
        case .days100: "days100"
        case .goodWeek: "goodWeek"
        case .goodMonth: "goodMonth"
        case .habit(let c): "habit." + c.rawValue
        }
    }

    static func badgeTitle(_ badge: FoodBadges.Badge) -> String {
        switch badge {
        case .firstFullWeek: String(localized: "A full week")
        case .days30: String(localized: "30 days logged")
        case .days100: String(localized: "100 days logged")
        case .goodWeek: String(localized: "A week of 8")
        case .goodMonth: String(localized: "A month of 8")
        case .habit(let c): String(localized: "Habit: \(component(c))")
        }
    }

    static func badgeDetail(_ badge: FoodBadges.Badge) -> String {
        switch badge {
        case .firstFullWeek: String(localized: "Every day of a week logged.")
        case .days30, .days100: String(localized: "Days that count, logged with at least a third of your usual food.")
        case .goodWeek: String(localized: "Your first week with a note of 8 or more.")
        case .goodMonth: String(localized: "Your first four weeks with a note of 8 or more.")
        case .habit: String(localized: "Eight points or more in this part, four weeks in a row.")
        }
    }

    static func badgeSymbol(_ badge: FoodBadges.Badge) -> String {
        switch badge {
        case .firstFullWeek: "calendar.badge.checkmark"
        case .days30: "30.circle.fill"
        case .days100: "rosette"
        case .goodWeek: "star.circle.fill"
        case .goodMonth: "star.square.on.square.fill"
        case .habit(let component): habitSymbol(component)
        }
    }

    /// A habit badge's symbol, one per part, so the medals can be told apart (Android `habitIcon`).
    static func habitSymbol(_ component: FoodScore.Component) -> String {
        switch component {
        case .vegetables: "carrot.fill"
        case .fruit: "basket.fill"
        case .wholeGrains: "fork.knife"
        case .nutsLegumes: "leaf.fill"
        case .redMeat: "flame.fill"
        case .processedMeat: "takeoutbag.and.cup.and.straw.fill"
        case .fishOmega3: "fish.fill"
        case .freeSugar: "cube.fill"
        case .satFat: "drop.fill"
        case .sodium: "circle.grid.3x3.fill"
        case .alcohol: "wineglass.fill"
        case .fiber: "leaf.circle.fill"
        }
    }

    /// Every badge there is, in the order the collection shows them.
    static var allBadges: [FoodBadges.Badge] {
        [.firstFullWeek, .days30, .days100, .goodWeek, .goodMonth]
            + FoodScore.Component.allCases.filter { $0 != .fiber }.map { .habit($0) }
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
