#if os(iOS)
import SwiftUI
import StrandDesign
import StrandCore
import StrandAnalytics
import WhoopStore

/// The redesign's Food page (decision 2026-11-08): one day of the food log. Calories eaten against the goal the
/// energy plan sets, the three macronutrients, the week's nutrients, and the meals in eating order.
struct ForgeFoodView: View {
    var onAsk: (String) -> Void = { _ in }

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var model = ForgeFoodModel()
    @State private var scrolledPast = false
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var showNutrients = false
    @State private var editing: FoodLogEntry?
    @State private var copying: FoodEntryBatch?
    @State private var recipeFrom: FoodEntryBatch?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // The day is named once, in the picker below, not again as an overline.
                ForgeDetailHeader(overline: nil, title: String(localized: "Food"), scrolledPast: $scrolledPast)
                FoodDayPicker(model: model)
                FoodEnergyCard(eaten: model.eatenKcal, calories: model.calories)
                FoodMacroRow(totals: model.summary?.totals ?? NutrientAmounts())
                FoodNutrientCard(report: model.nutrients, open: openNutrients)
                if let summary = model.summary, !summary.entries.isEmpty {
                    ForEach(summary.meals) { meal in
                        FoodMealCard(meal: meal, onEdit: { editing = $0 }, onCopy: { copying = FoodEntryBatch(entries: $0) },
                                     onRecipe: { recipeFrom = FoodEntryBatch(entries: $0) }, onDelete: delete)
                    }
                } else if model.summary != nil {
                    ContentUnavailableView("Nothing logged yet", systemImage: "fork.knife",
                                           description: Text("Search for a food, scan a barcode or just enter the calories."))
                        .forgeCard()
                }
                if model.catalogFailed {
                    Text("The food list could not be prepared. Your own foods and quick entries still work.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
                }
                ForgeExplainer(title: "Where the numbers come from",
                               text: "Foods come from the German Nutrient Database (BLS 4.0, Max Rubner-Institut) and, if you choose, from Open Food Facts. What you log also goes to Apple Health. Your goal follows your energy plan.") { EmptyView() }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .overlay(alignment: .bottom) { FoodAddButton(action: openAdd) }
        .background(ForgeBackground(tab: .today))
        .forgeDetailBar(title: String(localized: "Food"), showsTitle: scrolledPast)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Food data", systemImage: "gearshape", action: openSettings).labelStyle(.iconOnly)
            }
        }
        .task { await model.load(repo: repo, profile: Repository.analyticsProfile(profile)) }
        .onChange(of: model.day) { Task { await model.reload(repo: repo) } }
        .sheet(isPresented: $showAdd) { FoodAddSheet(model: model).environmentObject(repo) }
        .sheet(isPresented: $showSettings) { FoodDataSettingsView() }
        .sheet(item: $editing) { FoodEntrySheet(entry: $0, model: model).environmentObject(repo) }
        .sheet(item: $copying) { FoodCopySheet(batch: $0, model: model).environmentObject(repo) }
        .sheet(item: $recipeFrom) { FoodRecipeSheet(batch: $0, model: model).environmentObject(repo) }
        .navigationDestination(isPresented: $showNutrients) {
            if let report = model.nutrients { FoodNutrientsView(report: report) }
        }
    }

    private func openAdd() { showAdd = true }
    private func openSettings() { showSettings = true }
    private func openNutrients() { showNutrients = true }
    private func delete(_ entries: [FoodLogEntry]) { Task { await model.delete(entries, repo: repo) } }
}
#endif
