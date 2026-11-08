#if os(iOS)
import SwiftUI
import StrandCore
import StrandDesign

/// The Food page's centrepiece, standing free in the scene like the score rings: calories eaten as the outer ring,
/// protein, carbohydrate and fat as three finer rings inside it, and what is left of the day's goal in the middle.
struct FoodPlate: View {
    let eaten: Double
    let goal: Double?
    let totals: NutrientAmounts
    let macroGoals: FoodTargets.Macros?

    /// Outer ring and the three inner ones, each 4 pt apart.
    private static let outer = (diameter: 236.0, line: 18.0)
    private static let inner: [Double] = [199, 169, 139]
    private static let innerLine = 11.0

    var body: some View {
        ZStack {
            GlowRing(fraction: goal.map { eaten / max(1, $0) } ?? 0, value: 0, format: Self.blank,
                     color: ForgeColor.food, diameter: Self.outer.diameter, lineWidth: Self.outer.line)
                .shadow(color: ForgeColor.food.opacity(0.55), radius: 12)
            ForEach(Array(macros.enumerated()), id: \.offset) { index, macro in
                GlowRing(fraction: macro.share, value: 0, format: Self.blank, color: macro.tint,
                         diameter: Self.inner[index], lineWidth: Self.innerLine)
                    .shadow(color: macro.tint.opacity(0.5), radius: 8)
            }
            centre
        }
        .frame(width: Self.outer.diameter + Self.outer.line, height: Self.outer.diameter + Self.outer.line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    @ViewBuilder private var centre: some View {
        VStack(spacing: 0) {
            if let goal {
                let left = goal - eaten
                Text(FoodText.kcal(abs(left))).font(ForgeFont.rounded(38, .bold))
                    .foregroundStyle(left >= 0 ? ForgeColor.text : ForgeColor.effortInk)
                    .contentTransition(.numericText())
                Text(left >= 0 ? "kcal left" : "kcal over").font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
            } else {
                Text(FoodText.kcal(eaten)).font(ForgeFont.rounded(38, .bold)).foregroundStyle(ForgeColor.text)
                    .contentTransition(.numericText())
                Text("kcal eaten").font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
            }
        }
        .monospacedDigit()
        .animation(.smooth, value: eaten)
    }

    struct Macro { let name: String; let grams: Double; let goal: Double?; let tint: Color; let share: Double }

    /// The three macronutrients, each filled against its gram goal.
    var macros: [Macro] {
        func make(_ name: String, _ n: FoodNutrient, _ goal: Double?, _ tint: Color) -> Macro {
            let grams = totals[n] ?? 0
            return Macro(name: name, grams: grams, goal: goal, tint: tint, share: goal.map { grams / max(1, $0) } ?? 0)
        }
        return [make(String(localized: "Protein"), .proteinG, macroGoals?.proteinG, ForgeColor.protein),
                make(String(localized: "Carbs"), .carbsG, macroGoals?.carbsG, ForgeColor.carbs),
                make(String(localized: "Fat"), .fatG, macroGoals?.fatG, ForgeColor.fat)]
    }

    private var accessibilityText: String {
        var parts = [String(localized: "\(FoodText.kcal(eaten)) kcal eaten")]
        if let goal { parts.append(String(localized: "goal \(FoodText.kcal(goal)) kcal")) }
        for m in macros { parts.append("\(m.name) \(FoodText.grams(m.grams)) g") }
        return parts.joined(separator: ", ")
    }

    private static func blank(_: Double) -> String { "" }
}
#endif
