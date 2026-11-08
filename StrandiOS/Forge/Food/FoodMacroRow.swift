#if os(iOS)
import SwiftUI
import StrandCore

/// Protein, carbohydrate and fat of the day, each with its share of the day's energy.
struct FoodMacroRow: View {
    let totals: NutrientAmounts

    var body: some View {
        let p = totals[.proteinG] ?? 0, c = totals[.carbsG] ?? 0, f = totals[.fatG] ?? 0
        let energy = max(1, p * 4 + c * 4 + f * 9)
        HStack(spacing: 8) {
            FoodMacroTile(name: String(localized: "Protein"), grams: p, share: p * 4 / energy, tint: ForgeColor.protein)
            FoodMacroTile(name: String(localized: "Carbs"), grams: c, share: c * 4 / energy, tint: ForgeColor.carbs)
            FoodMacroTile(name: String(localized: "Fat"), grams: f, share: f * 9 / energy, tint: ForgeColor.fat)
        }
    }
}
#endif
