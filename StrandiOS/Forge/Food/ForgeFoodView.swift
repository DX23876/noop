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
    /// The one page pushed from Food. A single destination: two `isPresented` destinations on one view let
    /// SwiftUI open the wrong page (a tap on the score opened the nutrients).
    @State private var subpage: Subpage?

    enum Subpage: Hashable { case nutrients, score }
    @State private var editing: FoodLogEntry?
    @State private var copying: FoodEntryBatch?
    @State private var recipeFrom: FoodEntryBatch?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: FoodDayPicker.title(model.day), title: String(localized: "Food"),
                                  scrolledPast: $scrolledPast)
                hero
                if let other = model.otherIntake {
                    FoodOtherIntakeNote(kcal: other.kcal, source: other.source)
                }
                if !model.week.isEmpty {
                    FoodSectionHeader(title: String(localized: "Week"))
                        .padding(.top, 16)
                    FoodWeekStrip(week: model.week, shownDay: model.day, calorieGoal: model.calories?.kcal,
                                  macroGoals: model.macroGoals, select: showDay)
                    if model.scoreEnabled {
                        FoodScoreRow(score: model.score, loggedDays: model.scoreLoggedDays, open: openScore)
                            .disabled(model.score == nil)
                    }
                }
                FoodSectionHeader(title: String(localized: "Nutrients"), action: openNutrients)
                    .padding(.top, 16)
                FoodNutrientCard(day: model.dayNutrients, pinned: model.pinned, open: openNutrients)
                    .id(model.pinRevision)
                FoodSectionHeader(title: String(localized: "Meals"))
                    .padding(.top, 16)
                if let habit = model.habit {
                    FoodHabitCard(habit: habit, picture: FoodGroupMotif.forMeal(habit.entries).map { .motif($0) },
                                  add: logHabit, dismiss: model.dismissHabit)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if let summary = model.summary, !summary.entries.isEmpty {
                    ForEach(summary.meals) { meal in
                        FoodMealCard(meal: meal, picture: model.picture(for: meal), onEdit: { editing = $0 }, onCopy: { copying = FoodEntryBatch(entries: $0) },
                                     onRecipe: { recipeFrom = FoodEntryBatch(entries: $0) }, onDelete: delete)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } else if model.summary != nil {
                    ContentUnavailableView {
                        Label("Nothing logged yet", systemImage: "fork.knife")
                    } description: {
                        Text("Search for a food, scan a barcode or just enter the calories.")
                    } actions: {
                        Button("Add food", action: openAdd).buttonStyle(.borderedProminent).tint(ForgeColor.accent)
                    }
                    .forgeCard()
                }
                if model.catalogFailed {
                    Text("The food list could not be prepared. Your own foods and quick entries still work.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .animation(.smooth, value: model.summary?.entries.map(\.id))
            .animation(.smooth, value: model.habit)
            // The picture scrolls with the page and runs up under the bar; as a background it never sets the width.
            .background(alignment: .top) { FoodHeroPicture().padding(.top, -120) }
        }
        .background(ForgeBackground(tab: .today))
        .forgeDetailBar(title: String(localized: "Food"), showsTitle: scrolledPast)
        .toolbar {
            // Adding sits in the bar, always in reach, instead of a button floating over the meals.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Food data", systemImage: "gearshape", action: openSettings).labelStyle(.iconOnly)
                Button("Add food", systemImage: "plus", action: openAdd).labelStyle(.iconOnly)
            }
        }
        .sensoryFeedback(.success, trigger: model.savedRevision)
        .sensoryFeedback(.selection, trigger: model.day)
        .task { await model.load(repo: repo, profile: Repository.analyticsProfile(profile)) }
        .onChange(of: model.day) { Task { await model.reload(repo: repo) } }
        .sheet(isPresented: $showAdd) { FoodAddSheet(model: model).environmentObject(repo) }
        .sheet(isPresented: $showSettings, onDismiss: reloadGoals) { FoodDataSettingsView() }
        .sheet(item: $editing) { FoodEntrySheet(entry: $0, model: model).environmentObject(repo) }
        .sheet(item: $copying) { FoodCopySheet(batch: $0, model: model).environmentObject(repo) }
        .sheet(item: $recipeFrom) { FoodRecipeSheet(batch: $0, model: model).environmentObject(repo) }
        .navigationDestination(item: $subpage) { page in
            switch page {
            case .score:
                if let score = model.score { FoodScoreView(score: score, male: model.male == true) }
            case .nutrients:
                if let week = model.nutrients, let day = model.dayNutrients { FoodNutrientsView(week: week, day: day, model: model) }
            }
        }
    }

    /// The plate standing free in the scene, the day before and after on either side of it, the three
    /// macronutrients and the day's energy under it.
    private var hero: some View {
        let plate = FoodPlate(eaten: model.eatenKcal, goal: model.calories?.kcal,
                              totals: model.summary?.totals ?? NutrientAmounts(), macroGoals: model.macroGoals)
        return VStack(spacing: 24) {
            HStack(spacing: 0) {
                Button("Previous day", systemImage: "chevron.left", action: previousDay)
                    .frame(width: 44, height: 44)
                Spacer(minLength: 0)
                plate
                Spacer(minLength: 0)
                Button("Next day", systemImage: "chevron.right", action: nextDay)
                    .frame(width: 44, height: 44)
            }
            .labelStyle(.iconOnly)
            .font(.title3.weight(.semibold))
            .tint(ForgeColor.secondary)
            .gesture(DragGesture(minimumDistance: 30).onEnded(swipeDay))
            FoodPlateLegend(macros: plate.macros)
            FoodDayFigures(eaten: model.eatenKcal, calories: model.calories, burned: model.burned, isToday: model.isToday)
            let sentence = model.sentence()
            if !sentence.isEmpty {
                Text(FoodText.sentence(sentence))
                    .font(ForgeFont.body).foregroundStyle(ForgeColor.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
        .padding(.top, 8)
    }

    private func previousDay() { model.shiftDay(by: -1) }
    private func nextDay() { model.shiftDay(by: 1) }
    private func swipeDay(_ value: DragGesture.Value) {
        guard abs(value.translation.width) > abs(value.translation.height) else { return }
        model.shiftDay(by: value.translation.width < 0 ? 1 : -1)
    }

    private func openAdd() { showAdd = true }
    private func logHabit() { Task { await model.logHabit(repo: repo) } }
    private func reloadGoals() { Task { await model.reloadGoals(repo: repo, profile: Repository.analyticsProfile(profile)) } }
    private func openSettings() { showSettings = true }
    private func openNutrients() { subpage = .nutrients }
    private func openScore() { subpage = .score }
    private func showDay(_ day: String) { model.day = day }
    private func delete(_ entries: [FoodLogEntry]) { Task { await model.delete(entries, repo: repo) } }
}
#endif
