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
    /// Keeps what is in the cart as a meal to log again later; nil hides it.
    var saveAsMeal: (() -> Void)? = nil
    /// The day's energy with this cart, when it takes a losing day clearly over the goal (`FoodGoalState.overWarning`).
    var overGoal: (dayKcal: Double, goalKcal: Double)? = nil

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
            // Meal, time and keeping the cart as a meal on one line; the add button has a line of its own, so its
            // figure never wraps.
            HStack(spacing: 8) {
                FoodMealPicker(meal: $meal).labelsHidden().fixedSize()
                DatePicker("Time", selection: $time, displayedComponents: [.hourAndMinute]).labelsHidden()
                Spacer(minLength: 8)
                if let saveAsMeal {
                    Button(action: saveAsMeal) {
                        Label("Keep", systemImage: "star")
                            .font(ForgeFont.caption.weight(.semibold))
                            .foregroundStyle(ForgeColor.food)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(ForgeColor.fill, in: .capsule)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Save as meal"))
                }
            }
            if let overGoal {
                Label(String(localized: "With this, today comes to \(FoodText.kcal(overGoal.dayKcal)) of \(FoodText.kcal(overGoal.goalKcal)) kcal."),
                      systemImage: "exclamationmark.circle")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.effortInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            Button(action: add) {
                Group {
                    if saving { ProgressView() } else { Text("Add \(cart.count) · \(FoodText.kcal(total)) kcal").lineLimit(1) }
                }
                .font(.headline).foregroundStyle(ForgeColor.onAccent)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(ForgeColor.accent, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(saving)
        }
        .padding(12)
        // The whole bar takes touches: a tap between its controls must not reach the list behind it.
        .contentShape(.rect)
        .background(.regularMaterial)
    }

    private var total: Double? { NutrientAmounts.sum(cart.map(\.totals))[.energyKcal] }
    private func remove(_ line: FoodCartLine) { cart.removeAll { $0.id == line.id } }
}
#endif
