#if os(iOS)
import SwiftUI
import StrandCore

/// One food to pick: name, brand, calories per 100 g and where it is from.
struct FoodItemRow: View {
    let item: FoodItem
    let lastGrams: Double?
    let onPick: (FoodItem) -> Void
    let onFavourite: (FoodItem, Bool) -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.callout).bold().foregroundStyle(ForgeColor.text).lineLimit(2)
                    Text(detail).font(.footnote).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(ForgeColor.food).accessibilityHidden(true)
            }
        }
        .accessibilityHint(Text("Choose the amount"))
        .contextMenu {
            Button("Add to favourites", systemImage: "star", action: star)
            Button("Remove from favourites", systemImage: "star.slash", action: unstar)
        }
    }

    private var detail: String {
        var parts = ["\(FoodText.kcal(item.per100g[.energyKcal])) kcal / 100 g"]
        if let brand = item.brand { parts.insert(brand, at: 0) }
        if let lastGrams { parts.append(String(localized: "last \(FoodText.grams(lastGrams)) g")) }
        switch item.source {
        case .bls: parts.append("BLS")
        case .off, .online: parts.append("Open Food Facts")
        case .own: parts.append(String(localized: "yours"))
        case .recipe: parts.append(String(localized: "recipe"))
        }
        return parts.joined(separator: " · ")
    }

    private func pick() { onPick(item) }
    private func star() { onFavourite(item, true) }
    private func unstar() { onFavourite(item, false) }
}
#endif
