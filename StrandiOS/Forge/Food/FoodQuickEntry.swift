#if os(iOS)
import Foundation

/// A calorie figure without a food, as the quick sheet collects it.
struct FoodQuickEntry: Equatable {
    var name: String
    var kcal: Double
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var at: Date
}
#endif
