#if os(iOS)
import SwiftUI
import StrandCore

/// Every nutrient of the last seven logged days against its reference, grouped, with what it came from.
struct FoodNutrientsView: View {
    let report: FoodNutrientReport.Report
    @State private var scrolledPast = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: String(localized: "Last 7 days"), title: String(localized: "Nutrients"),
                                  scrolledPast: $scrolledPast)
                Text("Averages per logged day, each against its reference. One day says little; the references describe what you eat over time.")
                    .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
                ForEach(FoodNutrientReport.groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(FoodText.group(group.name)).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                            .padding(.bottom, 4)
                        ForEach(rows(group.nutrients), id: \.nutrient) { row in
                            Divider()
                            FoodNutrientRow(row: row)
                        }
                    }
                    .forgeCard()
                }
                Text("References: EFSA Dietary Reference Values for adults; salt and saturated fat: WHO. Not medical advice.")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary).padding(.horizontal, 4)
            }
            .padding(.horizontal, 16).padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .today))
        .forgeDetailBar(title: String(localized: "Nutrients"), showsTitle: scrolledPast)
    }

    private func rows(_ nutrients: [FoodNutrient]) -> [FoodNutrientReport.Row] {
        nutrients.compactMap { n in report.rows.first { $0.nutrient == n } }
    }
}
#endif
