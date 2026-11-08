#if os(iOS)
import SwiftUI
import StrandCore

/// The calorie goal (follow the energy plan, or a fixed number) and how it splits into protein, carbohydrate and fat.
struct FoodGoalsSection: View {
    @Binding var fixedKcal: Double
    @Binding var protein: Double
    @Binding var carbs: Double
    @Binding var fat: Double

    var body: some View {
        Section {
            Toggle("Fixed calorie goal", isOn: fixedOn)
            if fixedKcal > 0 {
                Stepper(value: $fixedKcal, in: 1_200...6_000, step: 50) {
                    LabeledContent("Goal", value: "\(FoodText.kcal(fixedKcal)) kcal")
                }
            }
            Stepper(value: $protein, in: 10...40, step: 5) { LabeledContent("Protein", value: "\(Int(protein)) %") }
            Stepper(value: $carbs, in: 20...65, step: 5) { LabeledContent("Carbs", value: "\(Int(carbs)) %") }
            Stepper(value: $fat, in: 15...45, step: 5) { LabeledContent("Fat", value: "\(Int(fat)) %") }
        } header: {
            Text("Goals")
        } footer: {
            Text(footer)
        }
    }

    /// The toggle's state is "a fixed number is set"; switching it on starts from 2,000 kcal.
    private var fixedOn: Binding<Bool> {
        Binding(get: { fixedKcal > 0 }, set: { fixedKcal = $0 ? max(fixedKcal, 2_000) : 0 })
    }

    private var footer: String {
        let total = Int(protein + carbs + fat)
        let base = fixedKcal > 0 ? String(localized: "Your fixed goal replaces the energy plan's.")
                                 : String(localized: "The calorie goal follows your energy plan.")
        let split = total == 100 ? "" : " " + String(localized: "The shares add up to \(total) %; Forge scales them to 100 %.")
        return base + split
    }
}
#endif
