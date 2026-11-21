#if os(iOS)
import SwiftUI
import StrandCore

/// One badge as a round medal: coloured when earned, a quiet outline while still to come.
struct FoodBadgeMedal: View {
    let badge: FoodBadges.Badge
    let earned: Bool
    var size: CGFloat = 56

    var body: some View {
        Image(systemName: FoodText.badgeSymbol(badge))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(earned ? ForgeColor.onAccent : ForgeColor.tertiary)
            .frame(width: size, height: size)
            .background(Circle().fill(earned ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(ForgeColor.fill)))
            .overlay(Circle().strokeBorder(ForgeColor.card, lineWidth: earned ? 2 : 0))
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch badge {
        case .firstFullWeek, .days30, .days100: ForgeColor.effort
        case .goodWeek, .goodMonth: ForgeColor.fat
        case .habit: ForgeColor.nutrientLeaf
        }
    }
}
#endif
