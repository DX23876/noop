#if os(iOS)
import SwiftUI
import StrandDesign
import StrandCore
import WhoopStore

/// Where product data comes from, as the wearer chose it after installing (decision 2026-11-08).
enum FoodProductDataPrefs {
    static let modeKey = "food.productData.mode"
    static let countriesKey = "food.productData.countries"
    static let unknownBarcodesOnlineKey = "food.productData.unknownBarcodesOnline"

    static var mode: FoodProductDataMode {
        FoodProductDataMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .none
    }
    /// Open Food Facts country tags for the online filter; the phone's region when none was chosen.
    static var countries: [String] {
        let saved = (UserDefaults.standard.string(forKey: countriesKey) ?? "").split(separator: ",").map(String.init)
        if !saved.isEmpty { return saved }
        return [FoodCountries.tag(forRegion: Locale.current.region?.identifier ?? "DE") ?? "germany"]
    }
    static var language: String { AppLanguage.activeLocale.language.languageCode?.identifier ?? "de" }
}

/// The add sheet: search, recent, favourites and own foods, a cart that is checked before anything is
/// saved, a quick calorie entry, the barcode scanner and, with the coach on, describing or photographing a meal.
struct ForgeFoodAddSheet: View {
    @ObservedObject var model: ForgeFoodModel
    var onAsk: (String) -> Void = { _ in }

    enum Tab: String, CaseIterable { case recent, favourites, mine }

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FoodProductDataPrefs.modeKey) private var modeRaw = FoodProductDataMode.none.rawValue
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @State private var query = ""
    @State private var tab: Tab = .recent
    @State private var results: [FoodItem] = []
    @State private var onlineResults: [FoodItem] = []
    @State private var onlineFailed = false
    @State private var recents: [(item: FoodItem, lastGrams: Double?)] = []
    @State private var favourites: [FoodItem] = []
    @State private var mine: [FoodItem] = []
    @State private var cart: [FoodCartLine] = []
    @State private var portionFor: FoodItem?
    @State private var showQuick = false
    @State private var showScan = false
    @State private var showDescribe = false
    @State private var showProductData = false
    @State private var meal: FoodLog.MealKind?
    @State private var time = Date()
    @State private var searchTask: Task<Void, Never>?

    private var mode: FoodProductDataMode { FoodProductDataMode(rawValue: modeRaw) ?? .none }

    var body: some View {
        NavigationStack {
            List {
                if mode == .none && query.isEmpty {
                    Section {
                        Button { showProductData = true } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Find branded products too").font(.headline).foregroundStyle(ForgeColor.text)
                                Text("Choose online search or download products for your country. Until then Forge searches the German Nutrient Database and your own foods, without the internet.")
                                    .font(.footnote).foregroundStyle(ForgeColor.secondary)
                            }
                        }
                    }
                }
                Section {
                    HStack(spacing: 10) {
                        actionButton(String(localized: "Scan"), "barcode.viewfinder") { showScan = true }
                        actionButton(String(localized: "Calories"), "number") { showQuick = true }
                        if coachFeatureEnabled {
                            actionButton(String(localized: "Describe"), "text.bubble") { showDescribe = true }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if query.isEmpty {
                    Picker("List", selection: $tab) {
                        Text("Recent").tag(Tab.recent)
                        Text("Favourites").tag(Tab.favourites)
                        Text("My foods").tag(Tab.mine)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    switch tab {
                    case .recent:
                        if recents.isEmpty { hint(String(localized: "What you log shows up here.")) }
                        ForEach(recents, id: \.item.id) { recent in itemRow(recent.item, lastGrams: recent.lastGrams) }
                    case .favourites:
                        if favourites.isEmpty { hint(String(localized: "Hold a food to add it to your favourites.")) }
                        ForEach(favourites) { itemRow($0) }
                    case .mine:
                        if mine.isEmpty { hint(String(localized: "Foods you scan or type in, and your recipes.")) }
                        ForEach(mine) { itemRow($0) }
                    }
                } else {
                    Section {
                        if results.isEmpty && onlineResults.isEmpty {
                            hint(String(localized: "Nothing found on this iPhone."))
                        }
                        ForEach(results) { itemRow($0) }
                    }
                    if mode == .online {
                        Section("Open Food Facts") {
                            if onlineFailed { hint(String(localized: "Online search is not reachable right now.")) }
                            ForEach(onlineResults) { itemRow($0) }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search foods"))
            .navigationTitle(Text("Add food"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { if !cart.isEmpty { cartBar } }
            .onChange(of: query) { _, value in scheduleSearch(value) }
            .task { await loadLists() }
            .sheet(item: $portionFor) { item in
                ForgeFoodPortionSheet(item: item, lastGrams: recents.first { $0.item.id == item.id }?.lastGrams) { line in
                    cart.append(line)
                }
            }
            .sheet(isPresented: $showQuick) {
                ForgeFoodQuickSheet(at: model.defaultTime()) { name, kcal, protein, carbs, fat, at in
                    Task {
                        if await model.quick(name: name, kcal: kcal, protein: protein, carbs: carbs, fat: fat, at: at,
                                             meal: meal, repo: repo) { dismiss() }
                    }
                }
            }
            .fullScreenCover(isPresented: $showScan) {
                ForgeFoodScanView { found in
                    showScan = false
                    portionFor = found
                    Task { await loadLists() }
                }
                .environmentObject(repo)
            }
            .sheet(isPresented: $showDescribe) {
                ForgeFoodDescribeSheet { lines in cart.append(contentsOf: lines) }
                    .environmentObject(repo)
            }
            .sheet(isPresented: $showProductData) { ForgeFoodProductDataView() }
            .onAppear { time = model.defaultTime() }
        }
    }

    // MARK: Rows

    private func actionButton(_ title: String, _ image: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: image).font(.system(.title3, weight: .semibold)).foregroundStyle(ForgeColor.food)
                Text(title).font(.system(.footnote, weight: .medium)).foregroundStyle(ForgeColor.text)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: ForgeRadius.inner, style: .continuous).fill(ForgeColor.fill))
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(ForgeColor.secondary)
    }

    private func itemRow(_ item: FoodItem, lastGrams: Double? = nil) -> some View {
        Button { portionFor = item } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(.callout, weight: .semibold)).foregroundStyle(ForgeColor.text).lineLimit(2)
                    Text(detail(item, lastGrams)).font(.footnote).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(ForgeColor.food)
            }
        }
        .contextMenu {
            Button { Task { await model.setFavourite(item, on: true, repo: repo); await loadLists() } } label: {
                Label("Add to favourites", systemImage: "star")
            }
            Button { Task { await model.setFavourite(item, on: false, repo: repo); await loadLists() } } label: {
                Label("Remove from favourites", systemImage: "star.slash")
            }
        }
    }

    private func detail(_ item: FoodItem, _ lastGrams: Double?) -> String {
        var parts = ["\(ForgeFoodModel.kcal(item.per100g[.energyKcal])) kcal / 100 g"]
        if let brand = item.brand { parts.insert(brand, at: 0) }
        if let lastGrams { parts.append(String(localized: "last \(ForgeFoodModel.grams(lastGrams)) g")) }
        switch item.source {
        case .bls: parts.append("BLS")
        case .off, .online: parts.append("Open Food Facts")
        case .own: parts.append(String(localized: "yours"))
        case .recipe: parts.append(String(localized: "recipe"))
        }
        return parts.joined(separator: " · ")
    }

    private var cartBar: some View {
        let kcal = NutrientAmounts.sum(cart.map(\.totals))[.energyKcal]
        return VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(cart) { line in
                        HStack(spacing: 4) {
                            Text("\(line.item.name) · \(ForgeFoodModel.grams(line.grams)) g").lineLimit(1)
                            Button { cart.removeAll { $0.id == line.id } } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel(Text("Remove"))
                        }
                        .font(.footnote).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(ForgeColor.fill))
                    }
                }
            }
            HStack {
                Picker("Meal", selection: $meal) {
                    Text("By time").tag(FoodLog.MealKind?.none)
                    ForEach(FoodLog.MealKind.allCases, id: \.self) { Text(ForgeFoodModel.mealName($0)).tag(FoodLog.MealKind?.some($0)) }
                }
                .labelsHidden()
                DatePicker("Time", selection: $time, displayedComponents: [.hourAndMinute]).labelsHidden()
                Spacer()
                Button {
                    Task {
                        // A result found online is kept as the wearer's own food, so it is there offline next time.
                        var lines = cart
                        if let store = await repo.storeHandle() {
                            for index in lines.indices where lines[index].item.source == .online {
                                if let saved = await FoodLibrary.saveOwn(store: store, lines[index].item, origin: .online) {
                                    lines[index].item = saved
                                }
                            }
                        }
                        let origin: FoodLogEntry.Origin = lines.contains { $0.item.source == .recipe } ? .recipe : .search
                        if await model.log(lines, at: time, meal: meal, origin: origin, repo: repo, coach: coach) { dismiss() }
                    }
                } label: {
                    Text("Add \(cart.count) · \(ForgeFoodModel.kcal(kcal)) kcal")
                        .font(.system(.headline)).foregroundStyle(ForgeColor.onAccent)
                        .padding(.horizontal, 18).frame(minHeight: 44)
                        .background(Capsule().fill(ForgeColor.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    // MARK: Loading

    private func loadLists() async {
        guard let store = await repo.storeHandle() else { return }
        recents = await FoodLibrary.recents(store: store)
        favourites = await FoodLibrary.favourites(store: store)
        let own = ((try? await store.customFoods()) ?? []).map(FoodLibrary.item(for:))
        let recipes = ((try? await store.foodRecipes()) ?? []).compactMap(FoodLog.item(for:))
        mine = recipes + own
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let store = await repo.storeHandle() else { return }
            let local = await FoodLibrary.search(store: store, query: value)
            guard !Task.isCancelled else { return }
            results = local
            onlineResults = []
            onlineFailed = false
            guard mode == .online, value.count >= FoodOnline.minimumQueryLength else { return }
            // Online waits for a real pause in typing: Open Food Facts allows about ten searches a minute.
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await FoodOnline.search(value, countries: FoodProductDataPrefs.countries,
                                                        language: FoodProductDataPrefs.language)
                guard !Task.isCancelled else { return }
                // A product already kept (with its filled nutrients) shows as the kept one, and only once.
                let kept = await FoodLibrary.preferKept(store: store, found)
                let localIds = Set(local.map(\.id))
                onlineResults = kept.filter { !localIds.contains($0.id) }
            } catch {
                if !Task.isCancelled { onlineFailed = true }
            }
        }
    }
}

/// How much of one food: grams, its portion, the last amount or 100 g, with the nutrients live.
struct ForgeFoodPortionSheet: View {
    let item: FoodItem
    var lastGrams: Double?
    let onAdd: (FoodCartLine) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double = 100
    @State private var portions: Double = 1

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.name).font(.headline)
                    if let brand = item.brand { Text(brand).foregroundStyle(ForgeColor.secondary) }
                }
                Section("Amount") {
                    HStack {
                        TextField("Grams", value: $grams, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                        Text("g").foregroundStyle(ForgeColor.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if let serving = item.servingG {
                                chip(item.servingLabel.map { String(localized: "1 portion (\($0))") }
                                     ?? String(localized: "1 portion (\(ForgeFoodModel.grams(serving)) g)"), serving)
                            }
                            if let lastGrams, lastGrams != item.servingG { chip(String(localized: "Last time \(ForgeFoodModel.grams(lastGrams)) g"), lastGrams) }
                            chip("100 g", 100)
                            chip("50 g", 50)
                            chip("250 g", 250)
                        }
                    }
                }
                Section("Nutrients") {
                    let totals = item.per100g.scaled(toGrams: grams)
                    row(String(localized: "Energy"), totals[.energyKcal], "kcal")
                    row(String(localized: "Protein"), totals[.proteinG], "g")
                    row(String(localized: "Carbs"), totals[.carbsG], "g")
                    row(String(localized: "Fat"), totals[.fatG], "g")
                    row(String(localized: "Fibre"), totals[.fiberG], "g")
                    row(String(localized: "Sugar"), totals[.sugarG], "g")
                    row(String(localized: "Salt"), totals[.saltG], "g")
                }
                if let from = item.estimatedFrom, let count = item.estimatedKeys?.count {
                    Section {
                        Text("\(count) vitamins and minerals are estimated from a similar food in the German Nutrient Database (\(from)).")
                            .font(.footnote).foregroundStyle(ForgeColor.secondary)
                    }
                }
                if item.source == .bls {
                    Section { Text("Source: German Nutrient Database (BLS 4.0), Max Rubner-Institut, CC BY 4.0.").font(.footnote).foregroundStyle(ForgeColor.secondary) }
                } else if item.source == .off || item.source == .online {
                    Section { Text("Source: Open Food Facts, ODbL. Values are entered by volunteers and can be wrong.").font(.footnote).foregroundStyle(ForgeColor.secondary) }
                }
            }
            .navigationTitle(Text("Amount"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let label = item.servingG.flatMap { abs($0 - grams) < 0.01 ? item.servingLabel ?? String(localized: "1 portion") : nil }
                        onAdd(FoodCartLine(item: item, grams: grams, portionLabel: label))
                        dismiss()
                    }
                    .disabled(!(grams > 0 && grams <= 10_000))
                }
            }
            .onAppear { grams = lastGrams ?? item.servingG ?? 100 }
        }
        .presentationDetents([.medium, .large])
    }

    private func chip(_ title: String, _ value: Double) -> some View {
        Button { grams = value } label: {
            Text(title).font(.footnote.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(abs(grams - value) < 0.01 ? ForgeColor.food.opacity(ForgeOpacity.band) : ForgeColor.fill))
                .foregroundStyle(ForgeColor.text)
        }
        .buttonStyle(.plain)
    }

    private func row(_ name: String, _ value: Double?, _ unit: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value.map { unit == "kcal" ? "\(ForgeFoodModel.kcal($0)) kcal" : "\(ForgeFoodModel.grams($0)) g" }
                 ?? String(localized: "not known"))
                .foregroundStyle(value == nil ? ForgeColor.tertiary : ForgeColor.text)
        }
    }
}

/// Calories without a food: a canteen plate, a restaurant meal.
struct ForgeFoodQuickSheet: View {
    let at: Date
    let onSave: (String, Double, Double?, Double?, Double?, Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kcal: Double?
    @State private var protein: Double?
    @State private var carbs: Double?
    @State private var fat: Double?
    @State private var time = Date()

    var body: some View {
        NavigationStack {
            Form {
                TextField("What was it?", text: $name)
                Section("Energy") {
                    TextField("kcal", value: $kcal, format: .number).keyboardType(.numberPad)
                }
                Section("If you know them") {
                    TextField("Protein (g)", value: $protein, format: .number).keyboardType(.decimalPad)
                    TextField("Carbs (g)", value: $carbs, format: .number).keyboardType(.decimalPad)
                    TextField("Fat (g)", value: $fat, format: .number).keyboardType(.decimalPad)
                }
                DatePicker("Time", selection: $time)
            }
            .navigationTitle(Text("Calories"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name.isEmpty ? String(localized: "Quick entry") : name, kcal ?? 0, protein, carbs, fat, time)
                        dismiss()
                    }
                    .disabled(!((kcal ?? -1) >= 0 && (kcal ?? 0) < 20_000))
                }
            }
            .onAppear { time = at }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
