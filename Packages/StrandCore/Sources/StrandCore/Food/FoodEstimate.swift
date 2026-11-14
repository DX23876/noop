import Foundation

/// Filling a product's missing nutrients from the most similar BLS food (decision 2026-11-08), the way food
/// composition tables borrow values: only nutrients the product does not state are taken, everything on the label
/// stays, and every borrowed value is marked. Choosing the BLS food is the coach's (`CoachFoodEstimate`); this part
/// is the arithmetic, shared and testable.
public enum FoodEstimate {
    /// The wearer's switch, the same key on both platforms. Off unless chosen; only offered with the coach on.
    public static let enabledKey = "food.estimateMissing"

    /// Never borrowed: these are always on a label and the label is the truth for them.
    public static let labelNutrients: Set<FoodNutrient> = [.energyKcal, .proteinG, .carbsG, .fatG, .sugarG, .satFatG,
                                                           .saltG, .sodiumMg, .alcoholG, .waterG]

    /// The vitamins and minerals a product leaves out.
    public static func missing(_ item: FoodItem) -> [FoodNutrient] {
        FoodNutrient.allCases.filter { !labelNutrients.contains($0) && item.per100g[$0] == nil }
    }

    /// Worth filling: a branded or typed-in product that states fewer than half of them. BLS foods and recipes
    /// built from them are complete already.
    public static func needsFilling(_ item: FoodItem) -> Bool {
        guard item.source != .bls, item.source != .recipe, item.estimatedFrom == nil else { return false }
        let candidates = FoodNutrient.allCases.filter { !labelNutrients.contains($0) }
        return missing(item).count * 2 > candidates.count
    }

    /// How different two foods are in make-up, in grams per 100 g over protein, carbohydrate, sugar and fat, with
    /// protein counted twice because it carries most of what dairy, meat and legumes bring. Nil when either lacks a
    /// macronutrient.
    public static func distance(_ a: FoodItem, _ b: FoodItem) -> Double? {
        var total = 0.0
        for (nutrient, weight) in [(FoodNutrient.proteinG, 2.0), (.carbsG, 1.0), (.fatG, 1.0)] {
            guard let x = a.per100g[nutrient], let y = b.per100g[nutrient] else { return nil }
            total += weight * abs(x - y)
        }
        if let x = a.per100g[.sugarG], let y = b.per100g[.sugarG] { total += abs(x - y) }
        return total
    }

    /// The largest make-up difference a borrowed value may come from. A product further from every candidate keeps
    /// only its label: an estimate from an unlike food is worse than none.
    public static let maximumDistance = 20.0

    /// Whether `reference` is close enough to lend values; protein must also be within 40 % or 3 g.
    public static func closeEnough(_ item: FoodItem, _ reference: FoodItem) -> Bool {
        guard let d = distance(item, reference), d <= maximumDistance,
              let p = item.per100g[.proteinG], let q = reference.per100g[.proteinG] else { return false }
        return abs(p - q) <= max(3, 0.4 * max(p, q))
    }

    /// Marks a nutrient the coach's model estimated freely, when no BLS food was close enough. Kept apart from
    /// borrowed BLS values in every entry, so a report can tell a measured neighbour from a model's guess.
    public static let aiPrefix = "ai:"
    public static let aiSource = "ai"

    /// `item` with the model's free estimates for its gaps. Values outside zero to 1.5 times the highest any BLS
    /// food has (`ceiling`) are dropped: a model's guess must at least be possible for some real food.
    public static func filledByModel(_ item: FoodItem, values: [FoodNutrient: Double],
                                     ceiling: (FoodNutrient) -> Double?) -> FoodItem {
        var next = item
        var keys: [String] = []
        for nutrient in missing(item) {
            guard let value = values[nutrient], value.isFinite, value >= 0,
                  let limit = ceiling(nutrient), value <= limit * 1.5 else { continue }
            next.per100g[nutrient] = value
            keys.append(aiPrefix + nutrient.rawValue)
        }
        guard !keys.isEmpty else { return item }
        next.estimatedFrom = aiSource
        // Marks already on the item stay: a computed energy value (`FoodEnergy`) is not a borrowed nutrient.
        next.estimatedKeys = ((item.estimatedKeys ?? []) + keys).sorted()
        return next
    }

    /// `item` with its gaps taken from `reference`, per 100 g, and marked.
    public static func filled(_ item: FoodItem, from reference: FoodItem) -> FoodItem {
        guard closeEnough(item, reference) else { return item }
        var next = item
        var borrowed: [String] = []
        for nutrient in missing(item) {
            if let value = reference.per100g[nutrient] {
                next.per100g[nutrient] = value
                borrowed.append(nutrient.rawValue)
            }
        }
        guard !borrowed.isEmpty else { return item }
        next.estimatedFrom = reference.id
        next.estimatedKeys = ((item.estimatedKeys ?? []) + borrowed).sorted()
        return next
    }
}
