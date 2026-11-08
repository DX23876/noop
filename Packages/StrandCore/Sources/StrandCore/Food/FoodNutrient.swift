import Foundation
import WhoopStore

/// The nutrients the food log knows, per 100 g of edible portion in the catalogue and per entry in the log.
/// The raw value is the column name in the catalogue table and the key in the stored JSON; the unit is the
/// part after the last underscore. Same order as `NUTRIENTS` in `Tools/food_catalog_common.py`
/// (`test_build_food_catalog` checks it).
public enum FoodNutrient: String, CaseIterable, Sendable, Codable {
    case energyKcal = "energy_kcal"
    case proteinG = "protein_g"
    case carbsG = "carbs_g"
    case fatG = "fat_g"
    case fiberG = "fiber_g"
    case sugarG = "sugar_g"
    case satFatG = "sat_fat_g"
    case monoFatG = "mono_fat_g"
    case polyFatG = "poly_fat_g"
    case omega3G = "omega3_g"
    case epaG = "epa_g"
    case dhaG = "dha_g"
    case alcoholG = "alcohol_g"
    case waterG = "water_g"
    case cholesterolMg = "cholesterol_mg"
    case sodiumMg = "sodium_mg"
    case saltG = "salt_g"
    case potassiumMg = "potassium_mg"
    case calciumMg = "calcium_mg"
    case magnesiumMg = "magnesium_mg"
    case phosphorusMg = "phosphorus_mg"
    case ironMg = "iron_mg"
    case zincMg = "zinc_mg"
    case iodineUg = "iodine_ug"
    case copperMg = "copper_mg"
    case manganeseMg = "manganese_mg"
    case vitaminAUg = "vitamin_a_ug"
    case vitaminDUg = "vitamin_d_ug"
    case vitaminEMg = "vitamin_e_mg"
    case vitaminKUg = "vitamin_k_ug"
    case thiaminMg = "thiamin_mg"
    case riboflavinMg = "riboflavin_mg"
    case niacinMg = "niacin_mg"
    case vitaminB6Mg = "vitamin_b6_mg"
    case folateUg = "folate_ug"
    case vitaminB12Ug = "vitamin_b12_ug"
    case vitaminCMg = "vitamin_c_mg"
    case pantothenicMg = "pantothenic_mg"
    case biotinUg = "biotin_ug"
}

extension FoodNutrient {
    public enum Unit: String, Sendable { case kcal, g, mg, ug }

    public var unit: Unit {
        switch rawValue.split(separator: "_").last {
        case "kcal": return .kcal
        case "mg": return .mg
        case "ug": return .ug
        default: return .g
        }
    }

    /// Energy and the three macronutrients: what every entry should know and the day totals bank.
    public static let macros: [FoodNutrient] = [.energyKcal, .proteinG, .carbsG, .fatG]
}

/// Nutrient amounts, the stored JSON's typed face. Missing means unknown, never zero.
public struct NutrientAmounts: Equatable, Sendable, Codable {
    public private(set) var values: [FoodNutrient: Double]

    public init(_ values: [FoodNutrient: Double] = [:]) {
        self.values = values.filter { $0.value.isFinite && $0.value >= 0 }
    }

    /// From stored JSON; keys this build does not know are dropped.
    public init(stored: FoodNutrientValues) {
        var out: [FoodNutrient: Double] = [:]
        for (key, value) in stored { if let nutrient = FoodNutrient(rawValue: key) { out[nutrient] = value } }
        self.init(out)
    }

    public var stored: FoodNutrientValues {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    public subscript(_ nutrient: FoodNutrient) -> Double? {
        get { values[nutrient] }
        set {
            if let newValue, newValue.isFinite, newValue >= 0 { values[nutrient] = newValue } else { values[nutrient] = nil }
        }
    }

    public var isEmpty: Bool { values.isEmpty }

    /// These amounts per 100 g, eaten as `grams`.
    public func scaled(toGrams grams: Double) -> NutrientAmounts {
        NutrientAmounts(values.mapValues { $0 * grams / 100 })
    }

    /// The sum. A nutrient known on one side only stays known: a sum of what was logged.
    public static func + (lhs: NutrientAmounts, rhs: NutrientAmounts) -> NutrientAmounts {
        NutrientAmounts(lhs.values.merging(rhs.values, uniquingKeysWith: +))
    }

    public static func sum(_ amounts: [NutrientAmounts]) -> NutrientAmounts {
        amounts.reduce(NutrientAmounts(), +)
    }

    /// As the stored JSON: canonical names to numbers.
    public init(from decoder: Decoder) throws {
        self.init(stored: try decoder.singleValueContainer().decode(FoodNutrientValues.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }
}
