#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// The add sheet: search, recent, favourites and own foods, a cart that is checked before anything is saved, a
/// quick calorie entry, the barcode scanner and, with the coach on, describing a meal.
struct FoodAddSheet: View {
    let model: ForgeFoodModel

    enum Tab: String, CaseIterable { case recent, favourites, mine }

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FoodProductDataPrefs.modeKey) private var modeRaw = FoodProductDataMode.none.rawValue
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @State private var search = FoodSearchModel()
    @State private var tab: Tab = .recent
    @State private var cart: [FoodCartLine] = []
    @State private var portionFor: FoodItem?
    @State private var showQuick = false
    @State private var showScan = false
    @State private var showDescribe = false
    @State private var showProductData = false
    @State private var meal: FoodLog.MealKind?
    @State private var time = Date.now
    @State private var saving = false

    private var mode: FoodProductDataMode { FoodProductDataMode(rawValue: modeRaw) ?? .none }

    var body: some View {
        NavigationStack {
            List {
                if mode == .none && search.query.isEmpty {
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
                Section {
                    FoodAddActions(coachOn: coachFeatureEnabled, scan: openScan, quick: openQuick, describe: openDescribe)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if search.query.isEmpty {
                    Picker("List", selection: $tab) {
                        Text("Recent").tag(Tab.recent)
                        Text("Favourites").tag(Tab.favourites)
                        Text("My foods").tag(Tab.mine)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    FoodListSection(items: listItems, empty: emptyText, lastGrams: search.lastGrams,
                                    onPick: pick, onFavourite: favourite)
                } else {
                    FoodListSection(items: search.local, empty: nil, lastGrams: search.lastGrams,
                                    onPick: pick, onFavourite: favourite)
                    if mode == .online {
                        Section("Open Food Facts") {
                            if search.onlineFailed {
                                Text("Online search is not reachable right now.").font(.footnote).foregroundStyle(ForgeColor.secondary)
                            }
                            ForEach(search.online) { item in
                                FoodItemRow(item: item, lastGrams: nil, onPick: pick, onFavourite: favourite)
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
                    FoodCartBar(cart: $cart, meal: $meal, time: $time, saving: saving, add: addCart)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: cart.isEmpty)
            .task(id: search.query) { await search.run(repo: repo, online: mode == .online) }
            .task { await search.loadLists(repo: repo); time = model.defaultTime() }
            .sheet(item: $portionFor) { item in
                FoodPortionSheet(item: item, lastGrams: search.lastGrams[item.id], add: addLine)
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
    }

    private var listItems: [FoodItem] {
        switch tab {
        case .recent: search.recents
        case .favourites: search.favourites
        case .mine: search.mine
        }
    }

    private var emptyText: String {
        switch tab {
        case .recent: String(localized: "What you log shows up here.")
        case .favourites: String(localized: "Hold a food to add it to your favourites.")
        case .mine: String(localized: "Foods you scan or type in, and your recipes.")
        }
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
