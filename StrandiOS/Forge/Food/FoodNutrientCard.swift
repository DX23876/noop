#if os(iOS)
import SwiftUI
import StrandCore

/// The pinned nutrients of the shown day against what is recommended. Everything else is on the nutrient page
/// the card opens.
struct FoodNutrientCard: View {
    let day: FoodNutrientReport.Report?
    let pinned: [FoodNutrient]
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(pinned, id: \.self) { nutrient in
                    FoodPinnedRow(nutrient: nutrient, row: day?.rows.first { $0.nutrient == nutrient })
                }
            }
            .forgeCard()
        }
        .buttonStyle(.plain)
    }
}
#endif
