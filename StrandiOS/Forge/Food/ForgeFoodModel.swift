#if os(iOS)
import Foundation
import Observation
import StrandCore
import StrandAnalytics
import WhoopStore

/// The Food page's state: one day of the shared food log (`FoodLog`), the calorie goal (`FoodTargets`) and the
/// seven-day nutrient report (`FoodNutrientReport`), plus the actions the page and its sheets run. Health writing
/// goes through `FoodHealthSync`, so every add or removal reaches Apple Health the same way.
@MainActor
@Observable
final class ForgeFoodModel {
    var day: String = Repository.localDayKey(.now)
    private(set) var summary: FoodLog.DaySummary?
    private(set) var calories: FoodTargets.Calories?
    private(set) var nutrients: FoodNutrientReport.Report?
    /// The shown day alone, for its nutrition facts and the pinned nutrients.
    private(set) var dayNutrients: FoodNutrientReport.Report?
    /// Gram goals for protein, carbohydrate and fat, from the calorie goal and the wearer's split.
    var macroGoals: FoodTargets.Macros? {
        guard let kcal = calories?.kcal else { return nil }
        let d = UserDefaults.standard, split = FoodTargets.defaultSplit
        func share(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
        return FoodTargets.macros(kcal: kcal, protein: share(FoodTargets.Keys.proteinPercent, split.protein),
                                  carbs: share(FoodTargets.Keys.carbsPercent, split.carbs),
                                  fat: share(FoodTargets.Keys.fatPercent, split.fat))
    }
    var pinned: [FoodNutrient] { FoodTargets.pinned(from: UserDefaults.standard.string(forKey: FoodTargets.Keys.pinned)) }
    private(set) var catalogFailed = false
    private(set) var loaded = false
    /// The plan's intake for the day when it comes from somewhere other than this log.
    private(set) var otherIntake: (kcal: Double, source: NutritionDay.Source)?

    @ObservationIgnored private var catalogReady = false
    @ObservationIgnored private var references: [FoodNutrient: FoodReference.Value] = [:]
    @ObservationIgnored private let plan = EnergyPlanModel()

    var isToday: Bool { day == Repository.localDayKey(.now) }
    /// What each recent day burned as measured by the strap and Health, today until now.
    @ObservationIgnored private var burnedByDay: [String: Double] = [:]
    private(set) var burnRevision = 0
    /// The shown day's measured burn; nil before the energy plan has loaded or beyond its window.
    var burned: Double? { _ = burnRevision; return burnedByDay[day] }
    var eatenKcal: Double { summary?.totals[.energyKcal] ?? 0 }

    func load(repo: Repository, profile: UserProfile) async {
        guard let store = await repo.storeHandle() else { return }
        // The day first, so the page fills before the catalogue and the energy plan have loaded.
        summary = await FoodLog.day(store: store, day)
        if !catalogReady {
            do { try await FoodCatalog.shared.prepareBundled(); catalogReady = true } catch { catalogFailed = true }
        }
        await plan.load(repo: repo, profile: profile)
        let planned = FoodTargets.calories(measuredMeanKcal: plan.burn.measuredMeanKcal,
                                           allDaysMeanKcal: plan.burn.allDaysMeanKcal,
                                           formulaTdeeKcal: plan.formulaTdee(profile: profile),
                                           dailyDeltaKcal: plan.targetDailyKcal)
        calories = FoodTargets.calories(fixedKcal: UserDefaults.standard.double(forKey: FoodTargets.Keys.calories), plan: planned)
        burnedByDay = plan.burnedByDay
        burnRevision += 1
        references = FoodReference.values(profileSex: profile.sex, age: Int(profile.age), weightKg: profile.weightKg,
                                          heightCm: profile.heightCm, energyKcal: calories?.kcal)
        await reload(store: store)
        loaded = true
    }

    /// After the goal settings changed.
    func reloadGoals(repo: Repository, profile: UserProfile) async { await load(repo: repo, profile: profile) }

    func reload(repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        await reload(store: store)
    }

    private func reload(store: WhoopStore) async {
        summary = await FoodLog.day(store: store, day)
        otherIntake = await FoodLog.otherIntake(store: store, day)
        if !references.isEmpty {
            nutrients = await FoodNutrientReport.report(store: store, to: day, references: references)
            dayNutrients = FoodNutrientReport.report(entries: summary?.entries ?? [], from: day, to: day, references: references)
        }
    }

    /// Pins or unpins a nutrient on the Food page (at most four; the oldest pin gives way).
    func togglePin(_ nutrient: FoodNutrient) {
        var list = pinned
        if let index = list.firstIndex(of: nutrient) { list.remove(at: index) } else { list.append(nutrient) }
        if list.count > 4 { list.removeFirst(list.count - 4) }
        UserDefaults.standard.set(list.map(\.rawValue).joined(separator: ","), forKey: FoodTargets.Keys.pinned)
        pinRevision += 1
    }
    /// Bumped on a pin change so views reading `pinned` refresh.
    private(set) var pinRevision = 0

    func shiftDay(by days: Int) {
        guard let date = WeightSeries.date(forDay: day),
              let next = Calendar.current.date(byAdding: .day, value: days, to: date) else { return }
        day = Repository.localDayKey(next)
    }

    /// When an entry added to this day is eaten: now on today, midday on another day.
    func defaultTime() -> Date {
        if isToday { return .now }
        let start = WeightSeries.date(forDay: day) ?? .now
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start
    }

    // MARK: Actions

    @discardableResult
    func log(_ lines: [FoodCartLine], at: Date, meal: FoodLog.MealKind?, repo: Repository, coach: AICoachEngine?) async -> Bool {
        guard let store = await repo.storeHandle(), !lines.isEmpty else { return false }
        var items = lines.map(\.item)
        // A result found online is kept as the wearer's own food, so it is there offline next time.
        for index in items.indices where items[index].source == .online {
            if let saved = await FoodLibrary.saveOwn(store: store, items[index], origin: .online) { items[index] = saved }
        }
        // Missing vitamins and minerals, from the closest BLS food or the coach's estimate, only when chosen.
        if let coach, CoachFeaturePrefs.isEnabled, UserDefaults.standard.bool(forKey: FoodEstimate.enabledKey) {
            items = await coach.fillingMissingNutrients(items, store: store)
        }
        let origin: FoodLogEntry.Origin = items.contains { $0.source == .recipe } ? .recipe : .search
        let entries = zip(lines, items).map { line, item in
            FoodLog.entry(for: item, grams: line.grams, at: at, origin: origin, portionLabel: line.portionLabel, meal: meal)
        }
        guard await FoodLog.save(store: store, entries) else { return false }
        await FoodHealthSync.wrote(entries, store: store)
        await reload(store: store)
        return true
    }

    @discardableResult
    func quick(_ quick: FoodQuickEntry, repo: Repository) async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        let entry = FoodLog.quickEntry(name: quick.name, kcal: quick.kcal, proteinG: quick.protein, carbsG: quick.carbs,
                                       fatG: quick.fat, at: quick.at)
        guard await FoodLog.save(store: store, [entry]) else { return false }
        await FoodHealthSync.wrote([entry], store: store)
        await reload(store: store)
        return true
    }

    func update(_ entry: FoodLogEntry, grams: Double?, at: Date?, meal: FoodLog.MealKind?, repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        let next = FoodLog.edited(entry, grams: grams, at: at, meal: .some(meal))
        guard await FoodLog.save(store: store, [next]) else { return }
        await FoodHealthSync.replaced(old: entry, new: next, store: store)
        await reload(store: store)
    }

    func delete(_ entries: [FoodLogEntry], repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        await FoodHealthSync.removed(await FoodLog.delete(store: store, ids: entries.map(\.id)))
        await reload(store: store)
    }

    func copy(_ entries: [FoodLogEntry], toDays days: [String], repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        let copies = FoodLog.copies(of: entries, toDays: days)
        guard await FoodLog.save(store: store, copies) else { return }
        await FoodHealthSync.wrote(copies, store: store)
        await reload(store: store)
    }

    func makeRecipe(name: String, from entries: [FoodLogEntry], servings: Double, repo: Repository) async -> Bool {
        guard let store = await repo.storeHandle(),
              let recipe = FoodLog.recipe(name: name, from: entries, servings: servings) else { return false }
        return (try? await store.saveFoodRecipe(recipe)) ?? false
    }

    func setFavourite(_ item: FoodItem, on: Bool, repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        try? await store.setFoodFavourite(.init(foodId: item.id, name: item.name,
                                                addedAt: Int(Date.now.timeIntervalSince1970)), on: on)
    }
}
#endif
