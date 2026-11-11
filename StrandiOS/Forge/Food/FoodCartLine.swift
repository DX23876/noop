#if os(iOS)
import Foundation
import StrandCore

/// One line of the add sheet's cart: a food and how much of it.
struct FoodCartLine: Identifiable, Equatable {
    let id = UUID()
    var item: FoodItem
    var grams: Double
    var portionLabel: String?
    /// The meal photo this line was found from, kept on the entry it becomes.
    var photoId: String?

    var totals: NutrientAmounts { item.per100g.scaled(toGrams: grams) }
}
#endif
