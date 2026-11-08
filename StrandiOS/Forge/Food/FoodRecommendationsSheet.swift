#if os(iOS)
import SwiftUI
import StrandCore

/// What each recommendation on the Nutrients page is based on, in words, behind the page's info button. The rows
/// themselves only state the amount; who recommends it and why lives here, once.
struct FoodRecommendationsSheet: View {
    /// The wearer's own amounts, shown beside each explanation.
    let report: FoodNutrientReport.Report
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The amounts describe what you eat over time. One day under or over means little, so the 7-day view is the one to judge by.")
                    Text("Tap a nutrient to see which foods it came from. Hold it to pin it to the Food page.")
                }
                Section("Protein") {
                    explanation(.proteinG, "0.83 g for every kilogram of a healthy body weight, the amount the European Food Safety Authority (EFSA) recommends for adults. If you train hard, more is fine.")
                }
                Section("Fibre") {
                    explanation(.fiberG, "The World Health Organization (WHO) and EFSA recommend at least 25 g; with 30 g or more the risk of heart disease, type 2 diabetes and bowel cancer is lowest.")
                }
                Section("Fats") {
                    explanation(.satFatG, "Saturated fat under a tenth of your calories, as the WHO recommends.")
                    explanation(.epaG, "At least 250 mg of the omega-3 fats from fish (EPA and DHA) a day, as EFSA recommends. One or two portions of oily fish a week cover it.")
                    Text("Monounsaturated and polyunsaturated fat, sugar and cholesterol have no daily amount of their own. They are shown so you can see where they come from.")
                        .foregroundStyle(ForgeColor.secondary)
                }
                Section("Salt") {
                    explanation(.saltG, "Under 5 g a day, as the WHO recommends.")
                    explanation(.sodiumMg, "Under 2 g of sodium a day, the amount EFSA considers safe. 5 g of salt contain 2 g of sodium.")
                }
                Section("Vitamins and minerals") {
                    Text("The amounts EFSA recommends for adults, for your sex and age. Where EFSA sets no recommended amount, its adequate intake is used. Thiamin and niacin grow with your calorie goal.")
                }
                Section {
                    Text("Recommendations are for healthy adults. They are not medical advice; pregnancy, illness or medication can change what you need.")
                        .foregroundStyle(ForgeColor.secondary)
                }
            }
            .font(ForgeFont.body)
            .navigationTitle("Recommendations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
            }
        }
        .presentationDetents([.large])
    }

    private func explanation(_ nutrient: FoodNutrient, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reference = report.rows.first(where: { $0.nutrient == nutrient })?.reference {
                HStack(spacing: 8) {
                    FoodNutrientBadge(nutrient: nutrient)
                    Text(FoodText.recommendation(reference, nutrient)).bold().foregroundStyle(ForgeColor.text)
                }
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func close() { dismiss() }
}
#endif
