#if os(iOS)
import SwiftUI

/// A tappable amount ("1 portion (40 g)", "100 g").
struct FoodPresetChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.footnote)
            .foregroundStyle(ForgeColor.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? ForgeColor.food.opacity(ForgeOpacity.band) : ForgeColor.fill, in: .capsule)
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
