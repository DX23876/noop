#if os(iOS)
import SwiftUI
import StrandCore

/// A list of foods with a hint when it is empty.
struct FoodListSection: View {
    let items: [FoodItem]
    let empty: String?
    let lastGrams: [String: Double]
    let onPick: (FoodItem) -> Void
    let onFavourite: (FoodItem, Bool) -> Void

    var body: some View {
        Section {
            if items.isEmpty, let empty {
                Text(empty).font(.footnote).foregroundStyle(ForgeColor.secondary)
            }
            ForEach(items) { item in
                FoodItemRow(item: item, lastGrams: lastGrams[item.id], onPick: onPick, onFavourite: onFavourite)
            }
        }
    }
}
#endif
