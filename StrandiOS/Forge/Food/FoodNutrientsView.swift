#if os(iOS)
import SwiftUI
import StrandCore

/// Every nutrient of the last seven logged days against its reference, grouped, with what it came from.
struct FoodNutrientsView: View {
    let week: FoodNutrientReport.Report
    let day: FoodNutrientReport.Report
    let model: ForgeFoodModel
    @State private var scrolledPast = false
    @State private var span: Span = .week
    @State private var showRecommendations = false

    enum Span: String, CaseIterable { case day, week }

    private var report: FoodNutrientReport.Report { span == .week ? week : day }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: nil, title: String(localized: "Nutrients"), scrolledPast: $scrolledPast)
                Picker("Span", selection: $span) {
                    Text("This day").tag(Span.day)
                    Text("Last 7 days").tag(Span.week)
                }
                .pickerStyle(.segmented)
                ForEach(FoodNutrientReport.groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(FoodText.group(group.name)).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                            .padding(.bottom, 4)
                        ForEach(rows(group.nutrients), id: \.nutrient) { row in
                            Divider()
                            FoodNutrientRow(row: row, pinned: model.pinned.contains(row.nutrient))
                                .contextMenu {
                                    Button(model.pinned.contains(row.nutrient) ? "Unpin from the Food page" : "Pin to the Food page",
                                           systemImage: model.pinned.contains(row.nutrient) ? "pin.slash" : "pin") {
                                        model.togglePin(row.nutrient)
                                    }
                                }
                        }
                    }
                    .forgeCard()
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .today))
        .forgeDetailBar(title: String(localized: "Nutrients"), showsTitle: scrolledPast)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("What the recommendations are based on", systemImage: "info.circle", action: openRecommendations)
                    .labelStyle(.iconOnly)
            }
        }
        .sheet(isPresented: $showRecommendations) { FoodRecommendationsSheet(report: week) }
    }

    private func openRecommendations() { showRecommendations = true }

    private func rows(_ nutrients: [FoodNutrient]) -> [FoodNutrientReport.Row] {
        nutrients.compactMap { n in report.rows.first { $0.nutrient == n } }
    }
}
#endif
