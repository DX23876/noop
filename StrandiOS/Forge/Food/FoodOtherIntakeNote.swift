#if os(iOS)
import SwiftUI
import StrandCore

/// Says when the energy plan counts this day's calories from somewhere else (a typed day value or another app),
/// so the page never shows two intakes for one day without saying why.
struct FoodOtherIntakeNote: View {
    let kcal: Double
    let source: NutritionDay.Source

    var body: some View {
        Label {
            Text(source == .manual
                 ? "Your energy plan counts \(FoodText.kcal(kcal)) kcal for this day from \(sourceName). A typed day value wins over meals logged here."
                 : "Your energy plan counts \(FoodText.kcal(kcal)) kcal for this day from \(sourceName). Once you log meals here, they count instead.")
                .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(ForgeColor.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var sourceName: String {
        switch source {
        case .manual: String(localized: "the value you typed")
        case .appleHealth: "Apple Health"
        case .healthConnect: "Health Connect"
        case .csv: String(localized: "a CSV import")
        case .foodLog: String(localized: "the food log")
        }
    }
}
#endif
