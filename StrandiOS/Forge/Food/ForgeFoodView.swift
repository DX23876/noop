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
    /// Opens the add sheet once on arrival: Today's Log sheet and the Health card's button.
    var opensAdd = false
    /// Set when the page is the Nutrition tab's root (owner, 2026-11-21): it then wears the tabs' header with the
    /// coach, search and profile, the shown day beside the title. Pushed from elsewhere it keeps its back bar.
    var onProfile: (() -> Void)? = nil

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var model = ForgeFoodModel()
    /// Set once the arrival sheet has been shown, so coming back from a subpage does not open it again.
    @State private var openedAdd = false
    @State private var scrolledPast = false
    /// Whether the page has scrolled under the status bar, which then gets the tabs' backdrop.
    @State private var underClock = false
    /// The calendar day the page last knew as today. As the Nutrition tab the page lives as long as the app, so
    /// past midnight it would still show yesterday; a page left on today moves on with the date (`followToday`).
    @State private var knownToday = Repository.localDayKey(.now)
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAdd = false
    @State private var showSettings = false
    /// The first-visit setup (owner, 2026-11-09), shown while `FoodProductDataPrefs.setupNeeded`.
    @State private var showSetup = false
    @State private var setupAfterSettings = false
    /// The one page pushed from Food. A single destination: two `isPresented` destinations on one view let
    /// SwiftUI open the wrong page (a tap on the score opened the nutrients).
    @State private var subpage: Subpage?

    enum Subpage: Hashable { case nutrients, score, plan, badges }
    /// A badge earned since the page last celebrated one.
    @State private var celebrating: FoodBadges.Earned?
    @AppStorage(FoodReminders.invitedKey) private var reminderInvited = false
    @AppStorage(FoodTargets.Keys.mealPictures) private var mealPictures = true
    @State private var planning = false
    @State private var editing: FoodLogEntry?
    @State private var copying: FoodEntryBatch?
    @State private var recipeFrom: FoodEntryBatch?
    /// The meal being kept as a favourite, while its name is asked for.
    @State private var keeping: FoodEntryBatch?
    @State private var askingKeepName = false
    @State private var keepName = ""
    /// A starred food tapped in the favourites bar: its amount sheet, logged straight from there.
    @State private var favouritePick: FoodItem?
    @State private var mealEditor: FoodMealEditor.Target?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let onProfile {
                    ForgeLargeHeader(title: "Nutrition", subtitle: FoodDayPicker.title(model.day), onProfile: onProfile) {
                        ForgeCoachButton(page: .nutrition, day: model.day)
                        ForgeSearchButton()
                    }
                    .padding(.horizontal, -16)
                    // Once the page scrolls, the status bar gets the tabs' backdrop; at rest the picture keeps the
                    // top to itself (design critique 2026-11-28: text ran under the clock here only).
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY < 0 } action: { underClock = $0 }
                    // A tab hides its bar, so Add food is the button under the plate and Food data the row at the
                    // end of the page. As a second icon row here they made three header rows before the plate
                    // (design critique 2026-11-28).
                } else {
                    ForgeDetailHeader(overline: FoodDayPicker.title(model.day), title: String(localized: "Nutrition"),
                                      scrolledPast: $scrolledPast)
                }
                // The day's own row: arrows, the date with its calendar and a way back to today.
                FoodDayPicker(model: model)
                DietPlanLine(model: model, open: openPlan)
                DietBurnModelNote(model: model)
                hero
                addButton
                if let other = model.otherIntake {
                    FoodOtherIntakeNote(kcal: other.kcal, source: other.source)
                }
                if model.dayNote != nil {
                    FoodNoteCard(day: model.dayNote, week: model.weekNote, month: model.monthNote, goal: model.goalDay,
                                 isToday: model.isToday, streakDays: model.badges?.streakDays ?? 0, open: openScore)
                }
                if !model.week.isEmpty {
                    // The strip shows the seven days up to the one shown, not the calendar week Training's
                    // "This week" means; one word for both read as one thing (design critique 2026-11-28).
                    FoodSectionHeader(title: String(localized: "Last 7 days"))
                        .padding(.top, 16)
                    FoodWeekStrip(week: model.week, shownDay: model.day, calorieGoal: { model.calories(for: $0)?.kcal },
                                  macroGoals: { model.macroGoals(for: $0) }, select: showDay)
                    if let badges = model.badges {
                        FoodBadgesStrip(summary: badges, open: openBadges)
                    }
                    if !reminderInvited && !FoodReminders.morningOn && model.dayNote != nil {
                        FoodReminderInvite(accept: acceptReminders, decline: declineReminders)
                            .transition(.opacity)
                    }
                }
                FoodSectionHeader(title: String(localized: "Nutrients"), action: openNutrients)
                    .padding(.top, 16)
                FoodNutrientCard(day: model.dayNutrients, pinned: model.pinned, open: openNutrients)
                    .id(model.pinRevision)
                if !model.savedMeals.isEmpty || !model.favouriteFoods.isEmpty {
                    FoodSectionHeader(title: String(localized: "Favourites"))
                        .padding(.top, 16)
                    FoodFavouritesBar(meals: model.savedMeals, foods: model.favouriteFoods,
                                      logMeal: logSavedMeal, pickFood: pickFavourite,
                                      editMeal: { mealEditor = .edit($0) }, removeMeal: removeSavedMeal)
                }
                FoodSectionHeader(title: String(localized: "Meals"))
                    .padding(.top, 16)
                if let habit = model.habit {
                    FoodHabitCard(habit: habit, picture: FoodGroupMotif.forMeal(habit.entries).map { .motif($0) },
                                  add: logHabit, dismiss: model.dismissHabit)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if let summary = model.summary, !summary.entries.isEmpty {
                    ForEach(summary.meals) { meal in
                        FoodMealCard(meal: meal, picture: mealPictures ? model.picture(for: meal) : nil, onEdit: { editing = $0 }, onCopy: { copying = FoodEntryBatch(entries: $0) },
                                     onRecipe: { recipeFrom = FoodEntryBatch(entries: $0) }, onKeep: keep, onDelete: delete)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    FoodCompleteDayRow(complete: model.dayComplete, asks: asksComplete, toggle: toggleComplete)
                } else if model.summary != nil {
                    ContentUnavailableView {
                        Label("Nothing logged yet", systemImage: "fork.knife")
                    } description: {
                        Text("Search for a food, scan a barcode or just enter the calories.")
                    } actions: {
                        Button("Add food", action: openAdd).buttonStyle(.borderedProminent).tint(ForgeColor.nutritionAccent)
                            .foregroundStyle(ForgeColor.onNutritionAccent)
                    }
                    .forgeCard()
                }
                if model.catalogFailed {
                    Text("The food list could not be prepared. Your own foods and quick entries still work.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
                }
                if onProfile != nil {
                    // The bar's Food data, which a tab does not show.
                    ForgeGroup {
                        Button(action: openSettings) {
                            ForgeRow(systemImage: "gearshape", tint: ForgeColor.secondary,
                                     title: String(localized: "Food data"), plainMark: true)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
            .animation(.smooth, value: model.summary?.entries.map(\.id))
            .animation(.smooth, value: model.habit)
            // The picture scrolls with the page and runs up under the bar; as a background it never sets the width.
            .background(alignment: .top) { FoodHeroPicture().padding(.top, -120) }
        }
        .background(ForgeBackground(tab: .nutrition))
        .overlay {
            if onProfile != nil && underClock {
                ForgeStatusBarScrim(tab: .nutrition).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: underClock)
        .forgeDetailBar(title: String(localized: "Nutrition"), showsTitle: scrolledPast)
        .toolbar {
            // Adding sits in the bar, always in reach, instead of a button floating over the meals.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Food data", systemImage: "gearshape", action: openSettings).labelStyle(.iconOnly)
                Button("Add food", systemImage: "plus", action: openAdd).labelStyle(.iconOnly)
            }
        }
        #if DEBUG
        .onAppear { if CommandLine.arguments.contains("--demo-planner") { planning = true } }
        .onAppear { if CommandLine.arguments.contains("--demo-plan-page") { subpage = .plan } }
        #endif
        .onAppear {
            if FoodProductDataPrefs.setupNeeded, !showSetup {
                showSetup = true
                return
            }
            openAddOnArrival()
        }
        .sensoryFeedback(.success, trigger: model.savedRevision)
        .sensoryFeedback(.selection, trigger: model.day)
        .task {
            followToday()
            await model.load(repo: repo, profile: Repository.analyticsProfile(profile))
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { followToday() } }
        .onChange(of: model.day) { Task { await model.reload(repo: repo) } }
        .sheet(isPresented: $planning) { DietPlannerView(model: model).environmentObject(repo) }
        .sheet(isPresented: $showAdd) { FoodAddSheet(model: model).environmentObject(repo) }
        .sheet(isPresented: $showSettings, onDismiss: settingsClosed) { FoodDataSettingsView(openSetup: askSetup) }
        .sheet(isPresented: $showSetup, onDismiss: setupClosed) { FoodSetupSheet() }
        .sheet(item: $editing) { FoodEntrySheet(entry: $0, model: model).environmentObject(repo) }
        .sheet(item: $copying) { FoodCopySheet(batch: $0, model: model).environmentObject(repo) }
        .sheet(item: $recipeFrom) { FoodRecipeSheet(batch: $0, model: model).environmentObject(repo) }
        .sheet(item: $mealEditor) { FoodMealEditor(model: model, target: $0).environmentObject(repo) }
        .sheet(item: $celebrating, onDismiss: model.markBadgesSeen) { earned in
            FoodBadgeCelebration(earned: earned) { celebrating = nil }
        }
        .onChange(of: model.badges) { celebrateNewBadge() }
        .sheet(item: $favouritePick) { item in
            FoodPortionSheet(item: item, model: model, lastGrams: model.lastGrams[item.id], add: logFavourite)
        }
        .alert("Keep as favourite", isPresented: $askingKeepName) {
            TextField("Name", text: $keepName)
            Button("Cancel", role: .cancel) { keeping = nil }
            Button("Keep", action: saveKept)
        } message: {
            Text("Log the whole meal again with one tap from your favourites.")
        }
        .navigationDestination(item: $subpage) { page in
            switch page {
            case .score:
                FoodScoreView(day: try? model.dayNote?.get(), week: model.weekNote, month: model.monthNote,
                              trend: model.weekTrend, male: model.male == true)
            case .badges:
                if let badges = model.badges { FoodBadgesView(summary: badges) }
            case .plan:
                DietPlanView(model: model, onAsk: onAsk)
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
            // The day row above already pages the days; arrows here too made two pagers on one screen
            // (design critique 2026-11-28). A swipe over the plate still turns the day.
            plate
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 30).onEnded(swipeDay))
            FoodPlateLegend(macros: plate.macros)
            FoodDayFigures(eaten: model.eatenKcal, calories: model.calories, burned: model.burned, isToday: model.isToday)
            if model.plan != nil, model.phase(for: model.day) != .main {
                Label(FoodText.phase(model.phase(for: model.day)), systemImage: model.phase(for: model.day) == .dietBreak ? "pause.circle.fill" : "flag.checkered")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.chargeInk)
            }
            if let plan = model.plan, plan.effectiveDayShift > 0,
               (1...6).contains(DietTargets.weekTrainingCount(model.day, plan: plan, training: model.training)) {
                Label(model.isTrainingDay(model.day) ? String(localized: "Training day: more carbohydrate") : String(localized: "Rest day"),
                      systemImage: model.isTrainingDay(model.day) ? "dumbbell.fill" : "bed.double.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.isTrainingDay(model.day) ? ForgeColor.effortInk : ForgeColor.secondary)
            }
            if let bonus = model.calories?.activeBonusKcal, bonus >= DietActiveDay.shownFromKcal {
                Label("+\(FoodText.kcal(bonus)) kcal for your active day", systemImage: "flame.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.effortInk)
                    .contentTransition(.numericText())
            }
            let sentence = [FoodText.sentence(model.sentence()), model.offPlanSentence() ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            if !sentence.isEmpty {
                Text(sentence)
                    .font(ForgeFont.body).foregroundStyle(ForgeColor.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
        .padding(.top, 8)
    }

    /// Adding, right under the plate it fills: in reach without scrolling to the meals.
    private var addButton: some View {
        Button(action: openAdd) {
            Label("Add food", systemImage: "plus")
                .font(.system(.headline))
                .foregroundStyle(ForgeColor.onNutritionAccent)
                .padding(.horizontal, 24)
                .frame(minHeight: 48)
                .background(Capsule().fill(ForgeColor.nutritionAccent))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func swipeDay(_ value: DragGesture.Value) {
        guard abs(value.translation.width) > abs(value.translation.height) else { return }
        model.shiftDay(by: value.translation.width < 0 ? 1 : -1)
    }

    private func openAdd() { showAdd = true }
    /// From the evening on, an unmarked today with meals asks whether everything is logged.
    private var asksComplete: Bool {
        model.isToday && !model.dayComplete && Calendar.current.component(.hour, from: .now) >= FoodDaySentence.fromHour
    }
    private func toggleComplete() { Task { await model.setDayComplete(!model.dayComplete, repo: repo) } }
    /// The add sheet a route asked for, once: after the setup when that came first.
    private func openAddOnArrival() {
        guard opensAdd, !openedAdd else { return }
        openedAdd = true
        showAdd = true
    }
    private func askSetup() { setupAfterSettings = true }
    private func settingsClosed() {
        reloadGoals()
        if setupAfterSettings {
            setupAfterSettings = false
            showSetup = true
        }
    }
    private func setupClosed() {
        UserDefaults.standard.set(true, forKey: FoodProductDataPrefs.setupDoneKey)
        reloadGoals()
        openAddOnArrival()
    }
    private func logHabit() { Task { await model.logHabit(repo: repo) } }
    private func reloadGoals() { Task { await model.reloadGoals(repo: repo, profile: Repository.analyticsProfile(profile)) } }
    private func openSettings() { showSettings = true }

    /// A page showing today moves to the new today once the date has changed; another day stays where it was put.
    private func followToday() {
        let today = Repository.localDayKey(.now)
        guard today != knownToday else { return }
        if model.day == knownToday { model.day = today }
        knownToday = today
    }
    private func openNutrients() { subpage = .nutrients }
    private func openScore() { subpage = .score }
    private func openBadges() { subpage = .badges }
    private func acceptReminders() {
        reminderInvited = true
        Task {
            _ = await FoodReminders.set(FoodReminders.morningKey, on: true)
            _ = await FoodReminders.set(FoodReminders.eveningKey, on: true)
            FoodReminders.refresh(model: model)
        }
    }
    private func declineReminders() { reminderInvited = true }
    /// The newest badge not celebrated yet. The first time the page sees badges at all (a long log from before
    /// badges existed), they are taken as seen without a celebration, so nobody gets a pile of them at once.
    private func celebrateNewBadge() {
        guard celebrating == nil, let newest = model.unseenBadges.last else { return }
        if UserDefaults.standard.object(forKey: ForgeFoodModel.seenBadgesKey) == nil {
            model.markBadgesSeen()
            return
        }
        celebrating = newest
    }
    /// The plan page when there is a plan, else straight into the planner.
    private func openPlan() { if model.plan == nil { planning = true } else { subpage = .plan } }
    private func showDay(_ day: String) { model.day = day }
    private func delete(_ entries: [FoodLogEntry]) { Task { await model.delete(entries, repo: repo) } }

    private func keep(_ entries: [FoodLogEntry]) {
        keepName = model.suggestedName(for: entries)
        keeping = FoodEntryBatch(entries: entries)
        askingKeepName = true
    }
    private func saveKept() {
        guard let batch = keeping else { return }
        keeping = nil
        let name = keepName
        Task { _ = await model.saveMeal(name: name, from: batch.entries, repo: repo) }
    }
    private func logSavedMeal(_ meal: FoodSavedMeal) { Task { await model.logSavedMeal(meal, repo: repo) } }
    private func pickFavourite(_ item: FoodItem) { favouritePick = item }
    private func removeSavedMeal(_ meal: FoodSavedMeal) { Task { await model.deleteMeal(meal, repo: repo) } }
    private func logFavourite(_ line: FoodCartLine) {
        Task { _ = await model.log([line], at: model.defaultTime(), meal: nil, repo: repo, coach: nil) }
    }
}
#endif
