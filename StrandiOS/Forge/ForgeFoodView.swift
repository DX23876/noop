#if os(iOS)
import SwiftUI
import StrandDesign
import StrandCore
import StrandAnalytics
import WhoopStore

/// The redesign's Food page (decision 2026-11-08): one day of the food log. Calories eaten against the goal
/// the energy plan sets, the three macronutrients, the nutrients worth watching, and the meals in eating
/// order. Adding opens `ForgeFoodAddSheet`; a row edits its amount, time or meal.
struct ForgeFoodView: View {
    var onAsk: (String) -> Void = { _ in }

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @StateObject private var model = ForgeFoodModel()
    @State private var scrolledPast = false
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var editing: FoodLogEntry?
    @State private var copying: [FoodLogEntry]?
    @State private var recipeFrom: [FoodLogEntry]?

    private var analyticsProfile: UserProfile { Repository.analyticsProfile(profile) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: dayTitle, title: String(localized: "Food"), scrolledPast: $scrolledPast)
                dayPicker
                energyCard
                macroCard
                if let summary = model.summary, !summary.entries.isEmpty {
                    nutrientCard(summary.totals)
                    ForEach(summary.meals) { meal in mealCard(meal) }
                } else {
                    emptyCard
                }
                if model.catalogFailed {
                    Text("The food list could not be prepared. Your own foods and quick entries still work.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
                }
                ForgeExplainer(title: "Where the numbers come from",
                               text: "Foods come from the German Nutrient Database (BLS 4.0, Max Rubner-Institut) and, if you choose, from Open Food Facts. What you log here also goes to Apple Health. Your goal follows your energy plan: what you usually burn, plus or minus what your plan asks for.") { EmptyView() }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .overlay(alignment: .bottom) { addButton }
        .background(ForgeBackground(tab: .today))
        .forgeDetailBar(title: String(localized: "Food"), showsTitle: scrolledPast)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(Text("Food data"))
            }
        }
        .sheet(isPresented: $showSettings) { ForgeFoodProductDataView() }
        .task { await model.load(repo: repo, profile: analyticsProfile) }
        .onChange(of: model.day) { _, _ in Task { await model.reload(repo: repo) } }
        .sheet(isPresented: $showAdd) {
            ForgeFoodAddSheet(model: model, onAsk: onAsk)
                .environmentObject(repo)
        }
        .sheet(item: $editing) { entry in
            ForgeFoodEntrySheet(entry: entry, model: model).environmentObject(repo)
        }
        .sheet(item: Binding(get: { copying.map(EntryBatch.init) }, set: { copying = $0?.entries })) { batch in
            ForgeFoodCopySheet(entries: batch.entries, model: model).environmentObject(repo)
        }
        .alert("Save as recipe", isPresented: Binding(get: { recipeFrom != nil }, set: { if !$0 { recipeFrom = nil } })) {
            RecipeNameAlert(entries: recipeFrom ?? [], model: model)
        }
    }

    // MARK: Day

    private var dayTitle: String {
        if model.isToday { return String(localized: "Today") }
        guard let date = WeightSeries.date(forDay: model.day) else { return model.day }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))
    }

    private var dayPicker: some View {
        HStack {
            Button { model.shiftDay(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel(Text("Previous day"))
            Spacer()
            Text(dayTitle).font(.system(.headline, design: .rounded)).foregroundStyle(ForgeColor.text)
            Spacer()
            Button { model.shiftDay(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel(Text("Next day"))
        }
        .foregroundStyle(ForgeColor.accent)
        .font(.system(.body, weight: .semibold))
    }

    // MARK: Energy

    private var eaten: Double { model.summary?.totals[.energyKcal] ?? 0 }

    private var energyCard: some View {
        let goal = model.calories?.kcal
        let share = goal.map { min(1.2, eaten / max(1, $0)) } ?? 0
        return HStack(spacing: 18) {
            ZStack {
                Circle().stroke(ForgeColor.food.opacity(ForgeOpacity.band), lineWidth: 12)
                Circle().trim(from: 0, to: min(1, share))
                    .stroke(ForgeColor.food, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(ForgeFoodModel.kcal(eaten)).font(ForgeFont.rounded(26, .bold)).foregroundStyle(ForgeColor.text)
                    Text("kcal").font(.system(.caption)).foregroundStyle(ForgeColor.secondary)
                }
            }
            .frame(width: 112, height: 112)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(ForgeFoodModel.kcal(eaten)) kcal eaten"))
            VStack(alignment: .leading, spacing: 6) {
                if let goal {
                    let left = goal - eaten
                    Text(left >= 0 ? "\(ForgeFoodModel.kcal(left)) kcal left" : "\(ForgeFoodModel.kcal(-left)) kcal over")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(left >= 0 ? ForgeColor.text : ForgeColor.effortInk)
                    Text("Goal \(ForgeFoodModel.kcal(goal)) kcal")
                        .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    if let calories = model.calories {
                        Text(goalReason(calories)).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Eaten today").font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(ForgeColor.text)
                    Text("Set up your energy plan to get a daily goal.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .forgeCard()
    }

    private func goalReason(_ calories: FoodTargets.Calories) -> String {
        let burn = ForgeFoodModel.kcal(calories.burnKcal)
        let usual = calories.basis == .measured
            ? String(localized: "You usually burn about \(burn) kcal.")
            : String(localized: "Your body data suggests about \(burn) kcal a day.")
        guard calories.planDeltaKcal != 0 else { return usual }
        let change = ForgeFoodModel.kcal(abs(calories.planDeltaKcal))
        return usual + " " + (calories.planDeltaKcal < 0
            ? String(localized: "Your plan takes \(change) kcal off.")
            : String(localized: "Your plan adds \(change) kcal."))
    }

    // MARK: Macros

    private var macroCard: some View {
        let totals = model.summary?.totals ?? NutrientAmounts()
        let energy = max(1, (totals[.proteinG] ?? 0) * 4 + (totals[.carbsG] ?? 0) * 4 + (totals[.fatG] ?? 0) * 9)
        return HStack(spacing: 10) {
            macroTile(String(localized: "Protein"), totals[.proteinG], share: (totals[.proteinG] ?? 0) * 4 / energy, tint: ForgeColor.protein)
            macroTile(String(localized: "Carbs"), totals[.carbsG], share: (totals[.carbsG] ?? 0) * 4 / energy, tint: ForgeColor.carbs)
            macroTile(String(localized: "Fat"), totals[.fatG], share: (totals[.fatG] ?? 0) * 9 / energy, tint: ForgeColor.fat)
        }
    }

    private func macroTile(_ name: String, _ grams: Double?, share: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.system(.footnote, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(ForgeFoodModel.grams(grams ?? 0)).font(ForgeFont.rounded(22, .bold)).foregroundStyle(ForgeColor.text)
                Text("g").font(.system(.caption)).foregroundStyle(ForgeColor.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(ForgeOpacity.band))
                    Capsule().fill(tint).frame(width: geo.size.width * min(1, max(0, share)))
                }
            }
            .frame(height: 6)
            Text("\(Int((share * 100).rounded())) % of energy").font(.system(.caption2)).foregroundStyle(ForgeColor.secondary)
        }
        .forgeCard(padding: 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: Nutrients

    /// The nutrients most worth a glance, as plain amounts. Goals for them come with the nutrition score.
    private func nutrientCard(_ totals: NutrientAmounts) -> some View {
        let rows: [(String, FoodNutrient, String)] = [
            (String(localized: "Fibre"), .fiberG, "g"), (String(localized: "Sugar"), .sugarG, "g"),
            (String(localized: "Saturated fat"), .satFatG, "g"), (String(localized: "Salt"), .saltG, "g"),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Worth a look").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
            ForEach(rows, id: \.1) { row in
                HStack {
                    Text(row.0).font(ForgeFont.body).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Text(totals[row.1].map { "\(ForgeFoodModel.grams($0)) \(row.2)" } ?? String(localized: "not known"))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(totals[row.1] == nil ? ForgeColor.tertiary : ForgeColor.text)
                }
            }
        }
        .forgeCard()
    }

    // MARK: Meals

    private func mealCard(_ meal: FoodLog.Meal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(ForgeFoodModel.mealName(meal.kind)).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                Text(meal.start.formatted(.dateTime.hour().minute().locale(AppLanguage.activeLocale)))
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                Spacer()
                Text("\(ForgeFoodModel.kcal(meal.totals[.energyKcal])) kcal")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(ForgeColor.food)
                Menu {
                    Button { copying = meal.entries } label: { Label("Copy to other days", systemImage: "doc.on.doc") }
                    if meal.entries.contains(where: { $0.grams != nil }) {
                        Button { recipeFrom = meal.entries } label: { Label("Save as recipe", systemImage: "book.closed") }
                    }
                    Button(role: .destructive) { Task { await model.delete(meal.entries, repo: repo) } } label: {
                        Label("Delete meal", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(.body)).foregroundStyle(ForgeColor.secondary)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(Text("Meal actions"))
            }
            .padding(.bottom, 4)
            ForEach(Array(meal.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                Button { editing = entry } label: { entryRow(entry) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { copying = [entry] } label: { Label("Copy to other days", systemImage: "doc.on.doc") }
                        Button(role: .destructive) { Task { await model.delete([entry], repo: repo) } } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .forgeCard()
    }

    private func entryRow(_ entry: FoodLogEntry) -> some View {
        let totals = NutrientAmounts(stored: entry.totals)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(.callout, weight: .semibold)).foregroundStyle(ForgeColor.text).lineLimit(2)
                Text(entryDetail(entry, totals)).font(.system(.footnote)).foregroundStyle(ForgeColor.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(ForgeFoodModel.kcal(totals[.energyKcal])).font(ForgeFont.rounded(17, .semibold)).foregroundStyle(ForgeColor.text)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func entryDetail(_ entry: FoodLogEntry, _ totals: NutrientAmounts) -> String {
        var parts: [String] = []
        if let label = entry.portionLabel { parts.append(label) }
        else if let grams = entry.grams { parts.append("\(ForgeFoodModel.grams(grams)) g") }
        if let brand = entry.brand { parts.append(brand) }
        if let protein = totals[.proteinG] { parts.append(String(localized: "\(ForgeFoodModel.grams(protein)) g protein")) }
        return parts.joined(separator: " · ")
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "fork.knife").font(.system(.title2)).foregroundStyle(ForgeColor.food)
            Text("Nothing logged yet").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
            Text("Search for a food, scan a barcode or just enter the calories.")
                .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
        }
        .forgeCard()
    }

    private var addButton: some View {
        Button { showAdd = true } label: {
            Label("Add food", systemImage: "plus")
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(ForgeColor.onAccent)
                .padding(.horizontal, 24).frame(minHeight: 52)
                .background(Capsule().fill(ForgeColor.accent))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 16)
    }
}

/// Entries handed to a sheet together.
struct EntryBatch: Identifiable {
    let entries: [FoodLogEntry]
    var id: String { entries.map(\.id).joined(separator: ",") }
}

/// One entry: change the amount, the time or the meal, or delete it.
struct ForgeFoodEntrySheet: View {
    let entry: FoodLogEntry
    @ObservedObject var model: ForgeFoodModel
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double = 0
    @State private var time = Date()
    @State private var meal: FoodLog.MealKind?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(entry.name).font(.headline)
                    if let brand = entry.brand { Text(brand).foregroundStyle(ForgeColor.secondary) }
                }
                if entry.per100g != nil {
                    Section("Amount") {
                        HStack {
                            TextField("Grams", value: $grams, format: .number.precision(.fractionLength(0...1)))
                                .keyboardType(.decimalPad)
                            Text("g").foregroundStyle(ForgeColor.secondary)
                        }
                        let kcal = NutrientAmounts(stored: entry.per100g ?? [:]).scaled(toGrams: grams)[.energyKcal]
                        Text("\(ForgeFoodModel.kcal(kcal)) kcal").foregroundStyle(ForgeColor.secondary)
                    }
                }
                Section("When") {
                    DatePicker("Time", selection: $time)
                    Picker("Meal", selection: $meal) {
                        Text("By time").tag(FoodLog.MealKind?.none)
                        ForEach(FoodLog.MealKind.allCases, id: \.self) { kind in
                            Text(ForgeFoodModel.mealName(kind)).tag(FoodLog.MealKind?.some(kind))
                        }
                    }
                }
                Section {
                    Button("Delete", role: .destructive) {
                        Task { await model.delete([entry], repo: repo); dismiss() }
                    }
                }
            }
            .navigationTitle(Text("Edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.update(entry, grams: entry.per100g != nil && grams > 0 ? grams : nil,
                                               at: time, meal: .some(meal), repo: repo)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                grams = entry.grams ?? 0
                time = Date(timeIntervalSince1970: TimeInterval(entry.loggedAt))
                meal = entry.meal.flatMap(FoodLog.MealKind.init(rawValue:))
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Copy entries to tomorrow or to chosen days (Bevel's "copy to today, tomorrow or several days").
struct ForgeFoodCopySheet: View {
    let entries: [FoodLogEntry]
    @ObservedObject var model: ForgeFoodModel
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []

    private var days: [String] {
        let base = WeightSeries.date(forDay: model.day) ?? Date()
        return (-3...7).compactMap { offset in
            offset == 0 ? nil : Calendar.current.date(byAdding: .day, value: offset, to: base).map(Repository.localDayKey)
        }
    }

    var body: some View {
        NavigationStack {
            List(days, id: \.self) { day in
                Button {
                    if chosen.contains(day) { chosen.remove(day) } else { chosen.insert(day) }
                } label: {
                    HStack {
                        Text(WeightSeries.date(forDay: day)?.formatted(.dateTime.weekday(.wide).day().month().locale(AppLanguage.activeLocale)) ?? day)
                            .foregroundStyle(ForgeColor.text)
                        Spacer()
                        if chosen.contains(day) { Image(systemName: "checkmark").foregroundStyle(ForgeColor.accent) }
                    }
                }
            }
            .navigationTitle(Text("Copy to"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        Task { await model.copy(entries, toDays: chosen.sorted(), repo: repo); dismiss() }
                    }
                    .disabled(chosen.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The recipe name prompt.
struct RecipeNameAlert: View {
    let entries: [FoodLogEntry]
    @ObservedObject var model: ForgeFoodModel
    @EnvironmentObject private var repo: Repository
    @State private var name = ""
    @State private var servings = "1"

    var body: some View {
        TextField("Name", text: $name)
        TextField("Servings", text: $servings).keyboardType(.numberPad)
        Button("Save") {
            let count = Double(servings) ?? 1
            Task { _ = await model.makeRecipe(name: name.isEmpty ? String(localized: "Recipe") : name,
                                              from: entries, servings: max(1, count), repo: repo) }
        }
        Button("Cancel", role: .cancel) {}
    }
}
#endif
