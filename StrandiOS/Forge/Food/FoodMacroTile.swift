#if os(iOS)
import SwiftUI

/// One macronutrient: grams, and a bar of its share of the day's energy.
struct FoodMacroTile: View {
    let name: String
    let grams: Double
    let share: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.footnote).bold().foregroundStyle(ForgeColor.secondary)
            Text("\(FoodText.grams(grams)) g").font(ForgeFont.rounded(22, .bold)).foregroundStyle(ForgeColor.text)
                .contentTransition(.numericText())
            FoodShareBar(share: share, tint: tint)
            Text("\(FoodText.percent(share)) of energy").font(.caption).foregroundStyle(ForgeColor.secondary)
        }
        .forgeCard(padding: 12)
        .accessibilityElement(children: .combine)
    }
}
#endif
