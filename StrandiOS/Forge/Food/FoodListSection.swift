#if os(iOS)
import SwiftUI
import StrandCore

/// A list of foods under an optional heading, with a hint when it is empty.
struct FoodListSection: View {
    var title: String? = nil
    let items: [FoodItem]
    let empty: String?
    let lastGrams: [String: Double]
    var favouriteIds: Set<String> = []
    let onPick: (FoodItem) -> Void
    let onFavourite: (FoodItem, Bool) -> Void
    var onQuickAdd: ((FoodItem, Double) -> Void)? = nil

    var body: some View {
        Section {
            if items.isEmpty, let empty {
                Text(empty).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
            ForEach(items) { item in
                FoodItemRow(item: item, lastGrams: lastGrams[item.id], isFavourite: favouriteIds.contains(item.id),
                            onPick: onPick, onFavourite: onFavourite, onQuickAdd: onQuickAdd)
            }
        } header: {
            if let title { Text(title) }
        }
    }
}
#endif
