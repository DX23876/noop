#if os(iOS)
import SwiftUI
import StrandCore

/// The meal an entry belongs to, or "by time" to let its time decide.
struct FoodMealPicker: View {
    @Binding var meal: FoodLog.MealKind?

    var body: some View {
        Picker("Meal", selection: $meal) {
            Text("By time").tag(FoodLog.MealKind?.none)
            ForEach(FoodLog.MealKind.allCases, id: \.self) { kind in
                Text(FoodText.meal(kind)).tag(FoodLog.MealKind?.some(kind))
            }
        }
    }
}
#endif
