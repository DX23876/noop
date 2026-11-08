#if os(iOS)
import SwiftUI

/// The three macronutrients under the plate, each by its ring's colour: grams eaten and the day's goal.
struct FoodPlateLegend: View {
    let macros: [FoodPlate.Macro]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(macros, id: \.name) { macro in
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(macro.tint).frame(width: 8, height: 8)
                        Text(macro.name).font(.footnote).foregroundStyle(ForgeColor.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(FoodText.grams(macro.grams))").font(ForgeFont.rounded(20, .semibold)).foregroundStyle(ForgeColor.text)
                            .contentTransition(.numericText())
                        Text(macro.goal.map { "/ \(FoodText.grams($0)) g" } ?? "g").font(.footnote).foregroundStyle(ForgeColor.secondary)
                    }
                    .monospacedDigit()
                    .animation(.smooth, value: macro.grams)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
#endif
