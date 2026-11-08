#if os(iOS)
import Foundation
import StrandCore
import StrandAnalytics
import WhoopStore

/// One line of the add sheet's cart: a food and how much of it.
struct FoodCartLine: Identifiable, Equatable {
    let id = UUID()
    var item: FoodItem
    var grams: Double
    var portionLabel: String?

    var totals: NutrientAmounts { item.per100g.scaled(toGrams: grams) }
}

/// The Food page's state: one day of the shared food log (`FoodLog`), the calorie goal from the energy plan
/// (`FoodTargets`), and the actions the page and the add sheet run. Health writing goes through
/// `FoodHealthSync`, so every add or removal reaches Apple Health the same way.
@MainActor
final class ForgeFoodModel: ObservableObject {
    @Published var day: String = Repository.localDayKey(Date())
    @Published private(set) var summary: FoodLog.DaySummary?
    @Published private(set) var calories: FoodTargets.Calories?
    @Published private(set) var catalogReady = false
    @Published private(set) var catalogFailed = false
    @Published private(set) var nutrients: FoodNutrientReport.Report?
    private var references: [FoodNutrient: FoodReference.Value] = [:]

    private let plan = EnergyPlanModel()

    var isToday: Bool { day == Repository.localDayKey(Date()) }

    func load(repo: Repository, profile: UserProfile) async {
        guard let store = await repo.storeHandle() else { return }
        if !catalogReady {
            do { try await FoodCatalog.shared.prepareBundled(); catalogReady = true } catch { catalogFailed = true }
        }
        summary = await FoodLog.day(store: store, day)
        await plan.load(repo: repo, profile: profile)
        calories = FoodTargets.calories(measuredMeanKcal: plan.burn.measuredMeanKcal,
                                        allDaysMeanKcal: plan.burn.allDaysMeanKcal,
                                        formulaTdeeKcal: plan.formulaTdee(profile: profile),
                                        dailyDeltaKcal: plan.targetDailyKcal)
        references = FoodReference.values(profileSex: profile.sex, age: Int(profile.age), weightKg: profile.weightKg,
                                          heightCm: profile.heightCm, energyKcal: calories?.kcal)
        nutrients = await FoodNutrientReport.report(store: store, to: day, references: references)
    }

    func reload(repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        summary = await FoodLog.day(store: store, day)
        if !references.isEmpty { nutrients = await FoodNutrientReport.report(store: store, to: day, references: references) }
    }

    func shiftDay(by days: Int) {
        guard let date = WeightSeries.date(forDay: day),
              let next = Calendar.current.date(byAdding: .day, value: days, to: date) else { return }
        day = Repository.localDayKey(next)
    }

    /// When an entry added to this day is eaten: now on today, midday on another day.
    func defaultTime() -> Date {
        if isToday { return Date() }
        let start = WeightSeries.date(forDay: day) ?? Date()
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start
    }

    // MARK: Actions

    @discardableResult
    func log(_ lines: [FoodCartLine], at: Date, meal: FoodLog.MealKind?, origin: FoodLogEntry.Origin,
             repo: Repository) async -> Bool {
        guard let store = await repo.storeHandle(), !lines.isEmpty else { return false }
        let entries = lines.map {
            FoodLog.entry(for: $0.item, grams: $0.grams, at: at, origin: origin, portionLabel: $0.portionLabel, meal: meal)
        }
        guard await FoodLog.save(store: store, entries) else { return false }
        await FoodHealthSync.wrote(entries, store: store)
        await reload(repo: repo)
        return true
    }

    @discardableResult
    func quick(name: String, kcal: Double, protein: Double?, carbs: Double?, fat: Double?, at: Date,
               meal: FoodLog.MealKind?, repo: Repository) async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        let entry = FoodLog.quickEntry(name: name, kcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat, at: at, meal: meal)
        guard await FoodLog.save(store: store, [entry]) else { return false }
        await FoodHealthSync.wrote([entry], store: store)
        await reload(repo: repo)
        return true
    }

    func update(_ entry: FoodLogEntry, grams: Double?, at: Date?, meal: FoodLog.MealKind??, repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        let next = FoodLog.edited(entry, grams: grams, at: at, meal: meal)
        guard await FoodLog.save(store: store, [next]) else { return }
        await FoodHealthSync.replaced(old: entry, new: next, store: store)
        await reload(repo: repo)
    }

    func delete(_ entries: [FoodLogEntry], repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        let removed = await FoodLog.delete(store: store, ids: entries.map(\.id))
        await FoodHealthSync.removed(removed)
        await reload(repo: repo)
    }

    func copy(_ entries: [FoodLogEntry], toDays days: [String], repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        let copies = FoodLog.copies(of: entries, toDays: days)
        guard await FoodLog.save(store: store, copies) else { return }
        await FoodHealthSync.wrote(copies, store: store)
        await reload(repo: repo)
    }

    func makeRecipe(name: String, from entries: [FoodLogEntry], servings: Double, repo: Repository) async -> Bool {
        guard let store = await repo.storeHandle(),
              let recipe = FoodLog.recipe(name: name, from: entries, servings: servings) else { return false }
        return (try? await store.saveFoodRecipe(recipe)) ?? false
    }

    func setFavourite(_ item: FoodItem, on: Bool, repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        try? await store.setFoodFavourite(.init(foodId: item.id, name: item.name,
                                                addedAt: Int(Date().timeIntervalSince1970)), on: on)
    }

    // MARK: Text

    static func kcal(_ value: Double?) -> String {
        guard let value else { return "–" }
        return Int(value.rounded()).formatted(.number.locale(AppLanguage.activeLocale))
    }

    static func grams(_ value: Double?) -> String {
        guard let value else { return "–" }
        let digits = value < 10 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(0...digits)).locale(AppLanguage.activeLocale))
    }

    static func mealName(_ kind: FoodLog.MealKind) -> String {
        switch kind {
        case .breakfast: return String(localized: "Breakfast")
        case .lunch: return String(localized: "Lunch")
        case .dinner: return String(localized: "Dinner")
        case .snack: return String(localized: "Snack")
        }
    }
}
#endif
