#if os(iOS)
import SwiftUI
import StrandCore

/// A nutrient's own small mark: a symbol for fats, fibre and sugar, the element for minerals (Fe, Ca), the letter
/// for vitamins (D, B12), each in its own colour, so a long list can be scanned by eye.
struct FoodNutrientBadge: View {
    let nutrient: FoodNutrient
    @ScaledMetric(relativeTo: .footnote) private var size = 32.0

    var body: some View {
        let tint = Self.tint(nutrient)
        Group {
            switch Self.mark(nutrient) {
            case .symbol(let name): Image(systemName: name).font(.footnote).bold()
            case .letters(let text): Text(text).font(.system(.caption, design: .rounded)).bold()
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .background(tint.opacity(ForgeOpacity.wash), in: .rect(cornerRadius: size * 0.3))
        .accessibilityHidden(true)
    }

    enum Mark { case symbol(String), letters(String) }

    /// The nutrient's colour, by what it is found in or known for. Only related nutrients share one (salt and
    /// sodium, the B vitamins).
    static func tint(_ n: FoodNutrient) -> Color {
        switch n {
        case .energyKcal: ForgeColor.food
        case .proteinG: ForgeColor.protein
        case .carbsG: ForgeColor.carbs
        case .fatG: ForgeColor.fat
        case .fiberG: ForgeColor.nutrientLeaf
        case .sugarG: ForgeColor.nutrientRose
        case .satFatG: ForgeColor.fat
        case .monoFatG: ForgeColor.nutrientOlive
        case .polyFatG: ForgeColor.nutrientSky
        case .omega3G: ForgeColor.cycleFollicular
        case .epaG, .dhaG: ForgeColor.nutrientSea
        case .cholesterolMg: ForgeColor.nutrientRed
        case .saltG, .sodiumMg: ForgeColor.nutrientSlate
        case .potassiumMg: ForgeColor.nutrientSun
        case .calciumMg: ForgeColor.nutrientSky
        case .magnesiumMg: ForgeColor.nutrientLeaf
        case .phosphorusMg: ForgeColor.nutrientIndigo
        case .ironMg: ForgeColor.nutrientRed
        case .zincMg: ForgeColor.nutrientSlate
        case .iodineUg: ForgeColor.nutrientSea
        case .copperMg: ForgeColor.nutrientCopper
        case .manganeseMg: ForgeColor.rest
        case .vitaminAUg: ForgeColor.nutrientCitrus
        case .vitaminDUg: ForgeColor.nutrientSun
        case .vitaminEMg: ForgeColor.nutrientOlive
        case .vitaminKUg: ForgeColor.nutrientLeaf
        case .thiaminMg, .riboflavinMg, .niacinMg, .pantothenicMg, .vitaminB6Mg, .biotinUg, .folateUg, .vitaminB12Ug:
            ForgeColor.nutrientIndigo
        case .vitaminCMg: ForgeColor.nutrientCitrus
        default: ForgeColor.secondary
        }
    }

    static func mark(_ n: FoodNutrient) -> Mark {
        switch n {
        case .proteinG: .symbol("dumbbell.fill")
        case .fiberG: .symbol("leaf.fill")
        case .sugarG: .symbol("cube.fill")
        case .satFatG: .symbol("drop.fill")
        case .monoFatG: .symbol("drop.halffull")
        case .polyFatG: .symbol("drop")
        case .omega3G: .letters("ω3")
        case .epaG: .symbol("fish.fill")
        case .cholesterolMg: .symbol("heart.fill")
        case .saltG: .symbol("circle.grid.3x3.fill")
        case .sodiumMg: .letters("Na")
        case .potassiumMg: .letters("K")
        case .calciumMg: .letters("Ca")
        case .magnesiumMg: .letters("Mg")
        case .phosphorusMg: .letters("P")
        case .ironMg: .letters("Fe")
        case .zincMg: .letters("Zn")
        case .iodineUg: .letters("I")
        case .copperMg: .letters("Cu")
        case .manganeseMg: .letters("Mn")
        case .vitaminAUg: .letters("A")
        case .vitaminDUg: .letters("D")
        case .vitaminEMg: .letters("E")
        case .vitaminKUg: .letters("K")
        case .thiaminMg: .letters("B1")
        case .riboflavinMg: .letters("B2")
        case .niacinMg: .letters("B3")
        case .pantothenicMg: .letters("B5")
        case .vitaminB6Mg: .letters("B6")
        case .biotinUg: .letters("B7")
        case .folateUg: .letters("B9")
        case .vitaminB12Ug: .letters("B12")
        case .vitaminCMg: .letters("C")
        case .energyKcal: .symbol("flame.fill")
        case .carbsG: .symbol("square.stack.3d.up.fill")
        case .fatG: .symbol("drop.circle.fill")
        default: .symbol("circle")
        }
    }
}
#endif
