#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// The Food page's favourites (2026-11-21): kept meals first, then starred foods, side by side. A meal is logged
/// with one tap; a food opens its amount, set to what was eaten last time.
struct FoodFavouritesBar: View {
    let meals: [FoodSavedMeal]
    let foods: [FoodItem]
    let logMeal: (FoodSavedMeal) -> Void
    let pickFood: (FoodItem) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(meals) { meal in
                    tile(motif: FoodSavedMealRow.motif(meal), title: meal.name,
                         detail: "\(FoodText.kcal(FoodLog.kcal(of: meal))) kcal") { logMeal(meal) }
                        .accessibilityLabel(Text("Log \(meal.name) again"))
                }
                ForEach(foods) { food in
                    tile(motif: FoodGroupMotif.forFoodId(food.id) ?? FoodGroupMotif.forGroup(food.group), title: food.name,
                         detail: "\(FoodText.kcal(food.per100g[.energyKcal])) kcal / 100 g") { pickFood(food) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .padding(.horizontal, -16)
    }

    private func tile(motif: FoodGroupMotif?, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                FoodThumbnail(motif: motif, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(ForgeFont.body.weight(.semibold)).foregroundStyle(ForgeColor.text).lineLimit(1)
                    Text(detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                }
                Image(systemName: "plus").font(ForgeFont.caption.weight(.bold)).foregroundStyle(ForgeColor.food)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 240, alignment: .leading)
            .background(ForgeColor.card, in: .rect(cornerRadius: ForgeRadius.card))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
#endif
