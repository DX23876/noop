#if os(iOS)
import SwiftUI
import StrandCore

/// Calories eaten against the day's goal: one ring, the figure left (or over), and where the goal comes from.
struct FoodEnergyCard: View {
    let eaten: Double
    let calories: FoodTargets.Calories?

    var body: some View {
        HStack(spacing: 20) {
            FoodRing(share: calories.map { eaten / max(1, $0.kcal) } ?? 0, tint: ForgeColor.food) {
                VStack(spacing: 0) {
                    Text(FoodText.kcal(eaten)).font(ForgeFont.rounded(26, .bold)).foregroundStyle(ForgeColor.text)
                        .contentTransition(.numericText())
                    Text("kcal").font(.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            .frame(width: 112, height: 112)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(FoodText.kcal(eaten)) kcal eaten"))
            VStack(alignment: .leading, spacing: 4) {
                if let calories {
                    let left = calories.kcal - eaten
                    Text(left >= 0 ? "\(FoodText.kcal(left)) kcal left" : "\(FoodText.kcal(-left)) kcal over")
                        .font(.title3).bold().foregroundStyle(left >= 0 ? ForgeColor.text : ForgeColor.effortInk)
                        .contentTransition(.numericText())
                    Text("Goal \(FoodText.kcal(calories.kcal)) kcal").font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    Text(reason(calories)).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Eaten today").font(.title3).bold().foregroundStyle(ForgeColor.text)
                    Text("Set up your energy plan to get a daily goal.").font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .forgeCard()
        .animation(.smooth, value: eaten)
    }

    private func reason(_ calories: FoodTargets.Calories) -> String {
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
