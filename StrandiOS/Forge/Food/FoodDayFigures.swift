#if os(iOS)
import SwiftUI
import StrandCore

/// Eaten, the goal and what the day burned, in one quiet row under the plate. A tap on the goal says how it is set.
struct FoodDayFigures: View {
    let eaten: Double
    let calories: FoodTargets.Calories?
    /// Measured by the strap and Health; today only until now, never a forecast.
    let burned: Double?
    let isToday: Bool
    @State private var showsGoalReason = false

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            FoodEnergyFigure(title: String(localized: "Eaten"), value: FoodText.kcal(eaten))
            if let calories {
                Button(action: explainGoal) {
                    FoodEnergyFigure(title: String(localized: "Goal"), value: FoodText.kcal(calories.kcal), showsInfo: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("How the goal is set"))
                .popover(isPresented: $showsGoalReason) {
                    Text(reason(calories)).font(ForgeFont.body).padding(16)
                        .frame(idealWidth: 280).fixedSize(horizontal: false, vertical: true)
                        .presentationCompactAdaptation(.popover)
                }
            }
            if let burned {
                FoodEnergyFigure(title: isToday ? String(localized: "Burned so far") : String(localized: "Burned"),
                                 value: FoodText.kcal(burned))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth, value: eaten)
        .animation(.smooth, value: burned)
    }

    private func explainGoal() { showsGoalReason = true }

    private func reason(_ calories: FoodTargets.Calories) -> String {
        if calories.basis == .fixed { return String(localized: "Your own fixed goal. You can change it in Food data.") }
        let burn = FoodText.kcal(calories.burnKcal)
        let usual = calories.basis == .measured
            ? String(localized: "You usually burn about \(burn) kcal.")
            : String(localized: "Your body data suggests about \(burn) kcal a day.")
        guard calories.planDeltaKcal != 0 else { return usual }
        let change = FoodText.kcal(abs(calories.planDeltaKcal))
        return usual + " " + (calories.planDeltaKcal < 0 ? String(localized: "Your plan takes \(change) kcal off.")
                                                          : String(localized: "Your plan adds \(change) kcal."))
    }
}
#endif
