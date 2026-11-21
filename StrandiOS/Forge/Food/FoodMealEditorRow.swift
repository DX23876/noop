#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// One food of the builder: its picture and name, what this amount brings, and the amount to change in place.
struct FoodMealEditorRow: View {
    @Binding var item: FoodRecipe.Item
    @FocusState private var editing: Bool
    /// The amount as typed. Emptied when the field is tapped, with the current amount as its grey placeholder, so
    /// typing replaces the amount; left empty, the amount stays as it was.
    @State private var typed = ""

    var body: some View {
        HStack(spacing: 12) {
            FoodThumbnail(motif: FoodGroupMotif.forFoodId(item.foodId), size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(ForgeFont.body).foregroundStyle(ForgeColor.text).lineLimit(2)
                Text("\(FoodText.kcal((item.per100g["energy_kcal"] ?? 0) * item.grams / 100)) kcal")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                TextField(FoodText.grams(item.grams), text: $typed)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 56)
                    .focused($editing)
                Text("g").foregroundStyle(ForgeColor.secondary)
            }
            .font(ForgeFont.body)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(ForgeColor.fill, in: .capsule)
            // The whole capsule takes the tap: the number alone is too small a target.
            .contentShape(.capsule)
            .onTapGesture { editing = true }
            .onAppear { typed = FoodText.grams(item.grams) }
            .onChange(of: editing) { _, focused in
                typed = focused ? "" : FoodText.grams(item.grams)
            }
            .onChange(of: typed) { _, text in
                // Only what the wearer types counts: the shown amount may carry a group separator ("1.000").
                guard editing else { return }
                if let grams = Double(text.replacingOccurrences(of: ",", with: ".")), grams > 0 { item.grams = grams }
            }
        }
    }
}
#endif
