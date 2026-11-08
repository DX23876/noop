#if os(iOS)
import SwiftUI
import StrandCore

/// The cart above the keyboard: what will be added, the meal and time, and one button with the total.
struct FoodCartBar: View {
    @Binding var cart: [FoodCartLine]
    @Binding var meal: FoodLog.MealKind?
    @Binding var time: Date
    let saving: Bool
    let add: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(cart) { line in
                        HStack(spacing: 4) {
                            Text("\(line.item.name) · \(FoodText.grams(line.grams)) g").lineLimit(1)
                            Button("Remove", systemImage: "xmark.circle.fill") { remove(line) }.labelStyle(.iconOnly)
                        }
                        .font(.footnote)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(ForgeColor.fill, in: .capsule)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .animation(.smooth, value: cart.map(\.id))
            HStack {
                FoodMealPicker(meal: $meal).labelsHidden()
                DatePicker("Time", selection: $time, displayedComponents: [.hourAndMinute]).labelsHidden()
                Spacer()
                Button(action: add) {
                    Group {
                        if saving { ProgressView() } else { Text("Add \(cart.count) · \(FoodText.kcal(total)) kcal") }
                    }
                    .font(.headline).foregroundStyle(ForgeColor.onAccent)
                    .padding(.horizontal, 20).frame(minHeight: 44)
                    .background(ForgeColor.accent, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(saving)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private var total: Double? { NutrientAmounts.sum(cart.map(\.totals))[.energyKcal] }
    private func remove(_ line: FoodCartLine) { cart.removeAll { $0.id == line.id } }
}
#endif
