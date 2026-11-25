#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// The add sheet: search, recent, favourites and own foods, a cart that is checked before anything is saved, a
/// quick calorie entry, the barcode scanner and, with the coach on, describing a meal.
struct FoodAddSheet: View {
    let model: ForgeFoodModel

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FoodProductDataPrefs.modeKey) private var modeRaw = FoodProductDataMode.none.rawValue
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @State private var search = FoodSearchModel()
    @State private var cart: [FoodCartLine] = []
    @State private var portionFor: FoodItem?
    @State private var showQuick = false
    @State private var showScan = false
    @State private var showDescribe = false
    @State private var showProductData = false
    @State private var meal: FoodLog.MealKind?
    @State private var time = Date.now
    @State private var saving = false
    @State private var quickAdded = 0
    @State private var mealEditor: FoodMealEditor.Target?
    @State private var namingCart = false
    @State private var cartName = ""
    @State private var keptCart = 0

    private var mode: FoodProductDataMode { FoodProductDataMode(rawValue: modeRaw) ?? .none }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    FoodAddActions(coachOn: coachFeatureEnabled, scan: openScan, quick: openQuick, describe: openDescribe)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if search.query.isEmpty {
                    favouritesSection
                    FoodListSection(title: String(localized: "Recent"), items: search.recents.filter { !model.favouriteIds.contains($0.id) },
                                    empty: String(localized: "What you log shows up here."), lastGrams: search.lastGrams,
                                    favouriteIds: model.favouriteIds, onPick: pick, onFavourite: favourite, onQuickAdd: quickAdd)
                    if !search.mine.isEmpty {
                        Section {
                            NavigationLink {
                                mineList
                            } label: {
                                LabeledContent("My foods", value: "\(search.mine.count)")
                                    .font(ForgeFont.cardTitle)
                            }
                        } footer: {
                            Text("Foods you scan or type in, and your recipes.")
                        }
                    }
                    if mode == .none {
                        Section {
                            Button(action: openProductData) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Find branded products too").font(.headline).foregroundStyle(ForgeColor.text)
                                    Text("Choose online search or a download for your country. Until then Forge searches the German Nutrient Database and your own foods, offline.")
                                        .font(.footnote).foregroundStyle(ForgeColor.secondary)
                                }
                            }
                        }
                    }
                } else {
                    FoodListSection(items: search.local, empty: nil, lastGrams: search.lastGrams,
                                    favouriteIds: model.favouriteIds, onPick: pick, onFavourite: favourite, onQuickAdd: quickAdd)
                    if mode == .online {
                        Section("Open Food Facts") {
                            if search.onlineFailed {
                                Text("Online search is not reachable right now.").font(.footnote).foregroundStyle(ForgeColor.secondary)
                            }
                            ForEach(search.online) { item in
                                FoodItemRow(item: item, lastGrams: nil, isFavourite: model.favouriteIds.contains(item.id),
                                            onPick: pick, onFavourite: favourite, onQuickAdd: quickAdd)
                            }
                        }
                    }
                }
            }
            .overlay {
                if !search.query.isEmpty && search.searched && search.local.isEmpty && search.online.isEmpty {
                    ContentUnavailableView.search
                }
            }
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search foods"))
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: close) } }
            .safeAreaInset(edge: .bottom) {
                if !cart.isEmpty {
                    FoodCartBar(cart: $cart, meal: $meal, time: $time, saving: saving, add: addCart, saveAsMeal: nameCart,
                                overGoal: overGoal)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: cart.isEmpty)
            .sensoryFeedback(.increase, trigger: quickAdded)
            .sensoryFeedback(.success, trigger: keptCart)
            .sheet(item: $mealEditor) { FoodMealEditor(model: model, target: $0).environmentObject(repo) }
            .alert("Save as meal", isPresented: $namingCart) {
                TextField("Name", text: $cartName)
                Button("Cancel", role: .cancel) {}
                Button("Save", action: keepCart)
            } message: {
                Text("Each food keeps its own values. The cart stays, so you can still add it now.")
            }
            .task(id: search.query) { await search.run(repo: repo, online: mode == .online) }
            .task { await search.loadLists(repo: repo); time = model.defaultTime() }
            .sheet(item: $portionFor) { item in
                FoodPortionSheet(item: item, model: model, lastGrams: search.lastGrams[item.id], add: addLine)
            }
            .sheet(isPresented: $showQuick) {
                FoodQuickSheet(at: model.defaultTime(), save: saveQuick)
            }
            .fullScreenCover(isPresented: $showScan) {
                FoodScanView(found: scanned).environmentObject(repo)
            }
            .sheet(isPresented: $showDescribe) {
                FoodDescribeSheet(add: addLines).environmentObject(repo).environmentObject(coach)
            }
            .sheet(isPresented: $showProductData) { FoodDataSettingsView() }
        }
        // One tint wherever the sheet is opened from: Today's stack and Health's tint their bars differently.
        .tint(ForgeColor.accent)
    }

    /// Kept meals and starred foods together, above everything else: what is eaten again and again sits first.
    @ViewBuilder private var favouritesSection: some View {
        Section {
            if model.savedMeals.isEmpty && model.favouriteFoods.isEmpty {
                Text("Star a food, build a meal, or keep one from its menu on the Food page, to find it here.")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
            ForEach(model.savedMeals) { meal in
                FoodSavedMealRow(meal: meal, log: logMeal, edit: editMeal, remove: removeMeal)
            }
            ForEach(model.favouriteFoods) { item in
                FoodItemRow(item: item, lastGrams: search.lastGrams[item.id] ?? model.lastGrams[item.id], isFavourite: true,
                            onPick: pick, onFavourite: favourite, onQuickAdd: quickAdd)
            }
            Button("Build a meal", systemImage: "plus.square.on.square", action: buildMeal)
                .font(ForgeFont.cardTitle)
                .foregroundStyle(ForgeColor.food)
        } header: {
            Text("Favourites")
        }
    }

    private var mineList: some View {
        List {
            FoodListSection(items: search.mine, empty: nil, lastGrams: search.lastGrams, favouriteIds: model.favouriteIds,
                            onPick: pick, onFavourite: favourite, onQuickAdd: quickAdd)
        }
        .navigationTitle("My foods")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Actions

    private func close() { dismiss() }
    private func openProductData() { showProductData = true }
    private func openScan() { showScan = true }
    private func openQuick() { showQuick = true }
    private func openDescribe() { showDescribe = true }
    private func pick(_ item: FoodItem) { portionFor = item }
    private func addLine(_ line: FoodCartLine) { cart.append(line) }
    private func addLines(_ lines: [FoodCartLine]) { cart.append(contentsOf: lines) }
    private func quickAdd(_ item: FoodItem, _ grams: Double) {
        cart.append(FoodItemRow.quickLine(item, grams))
        quickAdded += 1
    }

    /// A kept meal is logged at once; the sheet closes unless the cart still holds something to add.
    private func logMeal(_ meal: FoodSavedMeal) {
        Task {
            guard await model.logSavedMeal(meal, repo: repo) else { return }
            if cart.isEmpty { dismiss() }
        }
    }

    /// The warning while logging: only while losing weight, with the switch on, when the cart takes the day more than
    /// 20 % over its goal.
    private var overGoal: (dayKcal: Double, goalKcal: Double)? {
        let cartDay = Repository.localDayKey(time)
        guard FoodReminders.warnOn, let goal = model.calories(for: cartDay)?.kcal else { return nil }
        let adding = NutrientAmounts.sum(cart.map(\.totals))[.energyKcal] ?? 0
        let before = cartDay == model.day ? model.eatenKcal : 0
        return FoodGoalState.overWarning(dayKcal: before, adding: adding, goalKcal: goal, losing: model.losingWeight)
            .map { ($0, goal) }
    }

    private func removeMeal(_ meal: FoodSavedMeal) { Task { await model.deleteMeal(meal, repo: repo) } }
    private func editMeal(_ meal: FoodSavedMeal) { mealEditor = .edit(meal) }
    private func buildMeal() { mealEditor = .new }
    private func nameCart() {
        cartName = FoodText.meal(meal ?? FoodLog.MealKind.around(time))
        namingCart = true
    }
    private func keepCart() {
        let name = cartName
        let lines = cart
        Task { if await model.saveMeal(name: name, cart: lines, repo: repo) { keptCart += 1 } }
    }

    private func scanned(_ item: FoodItem) {
        showScan = false
        portionFor = item
        Task { await search.loadLists(repo: repo) }
    }

    private func favourite(_ item: FoodItem, _ on: Bool) {
        Task { await model.setFavourite(item, on: on, repo: repo); await search.loadLists(repo: repo) }
    }

    private func saveQuick(_ quick: FoodQuickEntry) {
        Task { if await model.quick(quick, repo: repo) { dismiss() } }
    }

    private func addCart() {
        saving = true
        Task {
            let done = await model.log(cart, at: time, meal: meal, repo: repo, coach: coach)
            saving = false
            if done { dismiss() }
        }
    }
}
#endif
