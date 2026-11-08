#if os(iOS)
import SwiftUI
import StrandCore

/// One numeric field with its unit, empty meaning unknown.
struct FoodValueField: View {
    let title: String
    let unit: FoodNutrient.Unit
    @Binding var value: Double?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("–", value: $value, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(minWidth: 64)
                Text(unitText).foregroundStyle(ForgeColor.secondary)
            }
        }
    }

    private var unitText: String {
        switch unit { case .kcal: "kcal"; case .g: "g"; case .mg: "mg"; case .ug: "µg" }
    }
}
#endif
