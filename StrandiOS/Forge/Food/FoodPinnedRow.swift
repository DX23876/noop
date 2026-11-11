#if os(iOS)
import SwiftUI
import StrandCore

/// One pinned nutrient for the day: the amount eaten against the recommended one, and a thin bar.
struct FoodPinnedRow: View {
    let nutrient: FoodNutrient
    let row: FoodNutrientReport.Row?

    var body: some View {
        HStack(spacing: 12) {
            FoodNutrientBadge(nutrient: nutrient)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(FoodText.nutrient(nutrient)).font(ForgeFont.body).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Text(FoodText.amount(eaten, nutrient)).font(.subheadline).bold().foregroundStyle(ForgeColor.text)
                    if let reference = row?.reference {
                        Text(reference.kind == .atLeast ? "of \(FoodText.amount(reference.amount, nutrient))"
                                                        : "max \(FoodText.amount(reference.amount, nutrient))")
                            .font(.footnote).foregroundStyle(ForgeColor.secondary)
                    }
                }
                if let reference = row?.reference {
                    let scale = max(reference.amount, eaten)
                    FoodShareBar(share: eaten / max(0.0001, scale), tint: tint(reference), height: 4)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var eaten: Double { row?.today ?? 0 }

    /// The nutrient's own colour while it is fine; amber when a limit is passed.
    private func tint(_ reference: FoodReference.Value) -> Color {
        reference.kind == .atMost && eaten > reference.amount ? ForgeColor.effort : FoodNutrientBadge.tint(nutrient)
    }
}
#endif
