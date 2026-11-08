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

    /// `item` with its gaps taken from `reference`, per 100 g, and marked.
    public static func filled(_ item: FoodItem, from reference: FoodItem) -> FoodItem {
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
        next.estimatedKeys = borrowed.sorted()
        return next
    }
}
