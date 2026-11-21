#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// A meal kept as a favourite, in the add sheet: its picture, name, foods and energy, and one button that logs it
/// again. Tapping the meal itself opens it in the builder; holding it offers editing and removal.
struct FoodSavedMealRow: View {
    let meal: FoodSavedMeal
    let log: (FoodSavedMeal) -> Void
    let edit: (FoodSavedMeal) -> Void
    let remove: (FoodSavedMeal) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: editMeal) {
                HStack(spacing: 12) {
                    FoodThumbnail(motif: FoodSavedMealRow.motif(meal))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meal.name).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text).lineLimit(1)
                        Text(FoodSavedMealRow.foods(meal)).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Edit meal"))
            Button(action: logMeal) {
                HStack(spacing: 4) {
                    Text("\(FoodText.kcal(FoodLog.kcal(of: meal))) kcal").monospacedDigit()
                    Image(systemName: "plus").fontWeight(.bold)
                }
                .font(ForgeFont.caption.weight(.semibold))
                .foregroundStyle(ForgeColor.food)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(ForgeColor.fill, in: .capsule)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Log \(meal.name) again"))
        }
        .contextMenu {
            Button("Edit meal", systemImage: "pencil", action: editMeal)
            Button("Remove from favourites", systemImage: "star.slash", role: .destructive, action: removeMeal)
        }
    }

    private func editMeal() { edit(meal) }
    private func logMeal() { log(meal) }
    private func removeMeal() { remove(meal) }

    /// The still life of the group that brings the most energy, as a logged meal shows it.
    static func motif(_ meal: FoodSavedMeal) -> FoodGroupMotif? {
        var kcal: [FoodGroupMotif: Double] = [:]
        for item in meal.items {
            guard let motif = FoodGroupMotif.forFoodId(item.foodId) else { continue }
            kcal[motif, default: 0] += (item.per100g["energy_kcal"] ?? 0) * item.grams / 100
        }
        return FoodGroupMotif.allCases.filter { kcal[$0] != nil }.max { (kcal[$0] ?? 0) < (kcal[$1] ?? 0) }
    }

    /// The foods by their short names ("Haferflocken, Vollmilch").
    static func foods(_ meal: FoodSavedMeal) -> String {
        meal.items.map { $0.name.components(separatedBy: ", ").first ?? $0.name }.joined(separator: ", ")
    }
}
#endif
