#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// One meal: its name, time and calories, a menu for the whole meal, and its entries.
struct FoodMealCard: View {
    let meal: FoodLog.Meal
    var picture: FoodMealPicture.Source? = nil
    let onEdit: (FoodLogEntry) -> Void
    let onCopy: ([FoodLogEntry]) -> Void
    let onRecipe: ([FoodLogEntry]) -> Void
    let onDelete: ([FoodLogEntry]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let picture {
                FoodMealPicture(source: picture).padding(.bottom, 12)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(FoodText.meal(meal.kind)).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                Text(meal.start, format: .dateTime.hour().minute()).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                Spacer()
                Text("\(FoodText.kcal(meal.totals[.energyKcal])) kcal").font(.subheadline).foregroundStyle(ForgeColor.secondary)
                Menu("Meal actions", systemImage: "ellipsis.circle") {
                    Button("Copy to other days", systemImage: "doc.on.doc", action: copyMeal)
                    if meal.entries.contains(where: { $0.grams != nil }) {
                        Button("Save as recipe", systemImage: "book.closed", action: recipeMeal)
                    }
                    Button("Delete meal", systemImage: "trash", role: .destructive, action: deleteMeal)
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(ForgeColor.secondary)
                .frame(minWidth: 44, minHeight: 44)
            }
            ForEach(meal.entries) { entry in
                Divider()
                FoodEntryRow(entry: entry, onEdit: onEdit, onCopy: { onCopy([$0]) }, onDelete: { onDelete([$0]) })
            }
        }
        .forgeCard()
    }

    private func copyMeal() { onCopy(meal.entries) }
    private func recipeMeal() { onRecipe(meal.entries) }
    private func deleteMeal() { onDelete(meal.entries) }
}
#endif
