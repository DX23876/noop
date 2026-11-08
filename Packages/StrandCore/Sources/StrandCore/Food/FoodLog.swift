import Foundation
import WhoopStore

/// The food log's operations, one implementation for the Apple screens, the Android screens and the coach.
/// Health writing is the host's: every call that adds or removes entries returns them, and the host writes or
/// deletes the matching Apple Health or Health Connect records, then stores the record id
/// (`WhoopStore.setFoodLogHealthId`).
public enum FoodLog {
    // MARK: Meals

    public enum MealKind: String, CaseIterable, Sendable, Codable {
        case breakfast, lunch, dinner, snack

        /// The meal a time of day usually is, when the wearer did not pick one.
        public static func around(_ date: Date, calendar: Calendar = .current) -> MealKind {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            switch minutes {
            case 4 * 60..<(10 * 60 + 30): return .breakfast
            case (11 * 60)..<(15 * 60): return .lunch
            case (17 * 60)..<(22 * 60): return .dinner
            default: return .snack
            }
        }
    }

    /// Entries eaten together: within `mealGap` of the previous one, or sharing a meal the wearer picked.
    public struct Meal: Equatable, Sendable, Identifiable {
        public var id: String { entries.first?.id ?? "" }
        public var kind: MealKind
        public var start: Date
        public var entries: [FoodLogEntry]
        public var totals: NutrientAmounts
    }

    public struct DaySummary: Equatable, Sendable {
        public var day: String
        public var entries: [FoodLogEntry]
        public var meals: [Meal]
        public var totals: NutrientAmounts
    }

    /// How far apart two entries can be and still be one meal.
    public static let mealGap: TimeInterval = 45 * 60

    public static func meals(_ entries: [FoodLogEntry], calendar: Calendar = .current) -> [Meal] {
        var meals: [Meal] = []
        for entry in entries.sorted(by: { ($0.loggedAt, $0.createdAt, $0.id) < ($1.loggedAt, $1.createdAt, $1.id) }) {
            let date = Date(timeIntervalSince1970: TimeInterval(entry.loggedAt))
            let kind = entry.meal.flatMap(MealKind.init(rawValue:)) ?? MealKind.around(date, calendar: calendar)
            if var last = meals.last, let previous = last.entries.last,
               (entry.meal != nil && entry.meal == previous.meal)
                || (entry.meal == nil && previous.meal == nil && TimeInterval(entry.loggedAt - previous.loggedAt) <= mealGap) {
                last.entries.append(entry)
                last.totals = last.totals + NutrientAmounts(stored: entry.totals)
                meals[meals.count - 1] = last
            } else {
                meals.append(Meal(kind: kind, start: date, entries: [entry], totals: NutrientAmounts(stored: entry.totals)))
            }
        }
        return meals
    }

    public static func day(store: WhoopStore, _ day: String) async -> DaySummary {
        let entries = (try? await store.foodLogEntries(from: day, to: day)) ?? []
        return DaySummary(day: day, entries: entries, meals: meals(entries),
                          totals: .sum(entries.map { NutrientAmounts(stored: $0.totals) }))
    }

    /// Day totals for a range, every logged day present, oldest first.
    public static func totals(store: WhoopStore, from: String, to: String) async -> [(day: String, totals: NutrientAmounts)] {
        let entries = (try? await store.foodLogEntries(from: from, to: to)) ?? []
        let grouped = Dictionary(grouping: entries, by: \.day)
        return grouped.keys.sorted().map { day in (day, .sum(grouped[day]!.map { NutrientAmounts(stored: $0.totals) })) }
    }

    // MARK: Entries

    /// A new entry for `grams` of `item`, eaten at `at`. Pure, so the arithmetic is testable on its own.
    public static func entry(for item: FoodItem, grams: Double, at: Date, origin: FoodLogEntry.Origin,
                             portionLabel: String? = nil, meal: MealKind? = nil, id: String = UUID().uuidString,
                             now: Date = Date()) -> FoodLogEntry {
        let stamp = Int(now.timeIntervalSince1970)
        return FoodLogEntry(
            id: id, loggedAt: Int(at.timeIntervalSince1970), day: StoreReader.localDayKey(at), meal: meal?.rawValue,
            foodId: item.id, name: item.name, brand: item.brand, grams: grams, portionLabel: portionLabel,
            per100g: item.per100g.stored, totals: item.per100g.scaled(toGrams: grams).stored, origin: origin,
            recipeId: item.source == .recipe ? String(item.id.dropFirst("recipe:".count)) : nil,
            createdAt: stamp, updatedAt: stamp, estimatedKeys: item.estimatedKeys ?? [])
    }

    /// A calorie figure without a food ("about 600 kcal at the canteen").
    public static func quickEntry(name: String, kcal: Double, proteinG: Double? = nil, carbsG: Double? = nil,
                                  fatG: Double? = nil, at: Date, meal: MealKind? = nil, id: String = UUID().uuidString,
                                  now: Date = Date()) -> FoodLogEntry {
        var totals = NutrientAmounts([.energyKcal: kcal])
        totals[.proteinG] = proteinG
        totals[.carbsG] = carbsG
        totals[.fatG] = fatG
        let stamp = Int(now.timeIntervalSince1970)
        return FoodLogEntry(id: id, loggedAt: Int(at.timeIntervalSince1970), day: StoreReader.localDayKey(at),
                            meal: meal?.rawValue, foodId: nil, name: name, grams: nil, per100g: nil,
                            totals: totals.stored, origin: .quick, createdAt: stamp, updatedAt: stamp)
    }

    /// The same entry with another amount, time or meal; totals follow the stored per-100 g snapshot.
    public static func edited(_ entry: FoodLogEntry, grams: Double? = nil, at: Date? = nil, meal: MealKind?? = nil,
                              portionLabel: String?? = nil, now: Date = Date()) -> FoodLogEntry {
        var next = entry
        if let grams, let per100g = entry.per100g {
            next.grams = grams
            next.totals = NutrientAmounts(stored: per100g).scaled(toGrams: grams).stored
        }
        if let at {
            next.loggedAt = Int(at.timeIntervalSince1970)
            next.day = StoreReader.localDayKey(at)
        }
        if let meal { next.meal = meal?.rawValue }
        if let portionLabel { next.portionLabel = portionLabel }
        next.updatedAt = Int(now.timeIntervalSince1970)
        return next
    }

    @discardableResult
    public static func save(store: WhoopStore, _ entries: [FoodLogEntry]) async -> Bool {
        (try? await store.saveFoodLogEntries(entries)) ?? false
    }

    @discardableResult
    public static func delete(store: WhoopStore, ids: [String]) async -> [FoodLogEntry] {
        (try? await store.deleteFoodLogEntries(ids: ids)) ?? []
    }

    /// Copies of entries on other days at the same time of day, as new entries without Health records.
    public static func copies(of entries: [FoodLogEntry], toDays days: [String], calendar: Calendar = .current,
                              now: Date = Date()) -> [FoodLogEntry] {
        let stamp = Int(now.timeIntervalSince1970)
        var out: [FoodLogEntry] = []
        for day in days {
            guard let start = WeightSeries.date(forDay: day) else { continue }
            for entry in entries {
                let eaten = Date(timeIntervalSince1970: TimeInterval(entry.loggedAt))
                let time = calendar.dateComponents([.hour, .minute, .second], from: eaten)
                guard let at = calendar.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0,
                                             second: time.second ?? 0, of: start) else { continue }
                var copy = entry
                copy.id = UUID().uuidString
                copy.loggedAt = Int(at.timeIntervalSince1970)
                copy.day = StoreReader.localDayKey(at)
                copy.origin = .copy
                copy.healthId = nil
                copy.createdAt = stamp
                copy.updatedAt = stamp
                out.append(copy)
            }
        }
        return out
    }

    // MARK: Recipes

    /// A recipe from logged entries (Bevel's "turn selected foods into a recipe"). Quick entries carry no
    /// amount and are left out.
    public static func recipe(name: String, from entries: [FoodLogEntry], servings: Double,
                              id: String = UUID().uuidString, now: Date = Date()) -> FoodRecipe? {
        let items = entries.compactMap { entry -> FoodRecipe.Item? in
            guard let grams = entry.grams, let per100g = entry.per100g else { return nil }
            return .init(foodId: entry.foodId, name: entry.name, grams: grams, per100g: per100g)
        }
        guard !items.isEmpty, servings > 0 else { return nil }
        let stamp = Int(now.timeIntervalSince1970)
        return FoodRecipe(id: id, name: name, servings: servings, items: items, createdAt: stamp, updatedAt: stamp)
    }

    /// A recipe as a food: per 100 g of the whole pot, one serving as its portion.
    public static func item(for recipe: FoodRecipe) -> FoodItem? {
        let grams = recipe.items.reduce(0) { $0 + $1.grams }
        guard grams > 0 else { return nil }
        let total = NutrientAmounts.sum(recipe.items.map { NutrientAmounts(stored: $0.per100g).scaled(toGrams: $0.grams) })
        return FoodItem(id: "recipe:\(recipe.id)", source: .recipe, name: recipe.name,
                        servingG: grams / recipe.servings, per100g: total.scaled(toGrams: 100 * 100 / grams))
    }
}

/// Where the add sheet finds foods: the wearer's own foods and recipes first, then the catalogues.
public enum FoodLibrary {
    /// The wearer's own foods and recipes matching the query, then BLS and the installed packs.
    public static func search(store: WhoopStore, catalog: FoodCatalog = .shared, query: String,
                              limit: Int = 40) async -> [FoodItem] {
        let words = FoodSearchText.tokens(query)
        guard !words.isEmpty else { return [] }
        func matches(_ text: String) -> Bool {
            let tokens = FoodSearchText.tokens(text)
            return words.allSatisfy { word in tokens.contains { $0.hasPrefix(word) } || FoodSearchText.normalised(text).contains(word) }
        }
        let own = ((try? await store.customFoods()) ?? []).map(item(for:)).filter { matches($0.name + " " + ($0.brand ?? "")) }
        let recipes = ((try? await store.foodRecipes()) ?? []).compactMap(FoodLog.item(for:)).filter { matches($0.name) }
        // A product kept as the wearer's own (often with its gaps filled) replaces its catalogue row.
        let kept = Set(((try? await store.customFoods()) ?? []).compactMap(\.sourceId))
        let catalogue = await catalog.search(query, limit: limit).filter { !kept.contains($0.id) }
        var seen = Set<String>()
        return (recipes + own + catalogue).filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    /// Foods eaten recently, as they were logged last time (their last amount is in `RecentFood.grams`).
    public static func recents(store: WhoopStore, limit: Int = 30) async -> [(item: FoodItem, lastGrams: Double?)] {
        ((try? await store.recentFoods(limit: limit)) ?? []).compactMap { recent in
            guard let per100g = recent.per100g else { return nil }
            let source: FoodItem.Source = recent.foodId.hasPrefix("bls:") ? .bls
                : recent.foodId.hasPrefix("off:") ? .off : recent.foodId.hasPrefix("recipe:") ? .recipe : .own
            return (FoodItem(id: recent.foodId, source: source, name: recent.name, brand: recent.brand,
                             per100g: NutrientAmounts(stored: per100g)), recent.grams)
        }
    }

    public static func favourites(store: WhoopStore, catalog: FoodCatalog = .shared) async -> [FoodItem] {
        var out: [FoodItem] = []
        for favourite in (try? await store.foodFavourites()) ?? [] {
            if let item = await item(store: store, catalog: catalog, id: favourite.foodId) { out.append(item) }
        }
        return out
    }

    public static func item(store: WhoopStore, catalog: FoodCatalog = .shared, id: String) async -> FoodItem? {
        if id.hasPrefix("own:"), let food = try? await store.customFood(id: id) { return item(for: food) }
        if id.hasPrefix("recipe:") {
            let recipeId = String(id.dropFirst("recipe:".count))
            return ((try? await store.foodRecipes()) ?? []).first { $0.id == recipeId }.flatMap(FoodLog.item(for:))
        }
        return await catalog.item(id: id)
    }

    /// A scanned barcode: the wearer's own scanned foods first, then the installed packs.
    public static func item(store: WhoopStore, catalog: FoodCatalog = .shared, barcode: String) async -> FoodItem? {
        for code in FoodCatalog.barcodeVariants(barcode) {
            if let food = try? await store.customFood(barcode: code) { return item(for: food) }
        }
        return await catalog.item(barcode: barcode)
    }

    /// Keeps a food as the wearer's own: from a label, an online result or by hand. Returns it as stored.
    public static func saveOwn(store: WhoopStore, _ food: FoodItem, origin: CustomFood.Origin,
                               now: Date = Date()) async -> FoodItem? {
        let stamp = Int(now.timeIntervalSince1970)
        let id = food.source == .own ? food.id : "own:\(UUID().uuidString)"
        let custom = CustomFood(id: id, name: food.name, brand: food.brand, barcode: food.barcode, group: food.group,
                                nova: food.nova, servingG: food.servingG, servingLabel: food.servingLabel,
                                per100g: food.per100g.stored, origin: origin,
                                sourceId: food.source == .own ? nil : food.id, createdAt: stamp, updatedAt: stamp,
                                estimatedFrom: food.estimatedFrom, estimatedKeys: food.estimatedKeys ?? [])
        guard (try? await store.saveCustomFood(custom)) == true else { return nil }
        return item(for: custom)
    }

    public static func item(for food: CustomFood) -> FoodItem {
        FoodItem(id: food.id, source: .own, name: food.name, brand: food.brand, group: food.group, nova: food.nova,
                 servingG: food.servingG, servingLabel: food.servingLabel,
                 per100g: NutrientAmounts(stored: food.per100g), barcode: food.barcode,
                 estimatedFrom: food.estimatedFrom, estimatedKeys: food.estimatedKeys.isEmpty ? nil : food.estimatedKeys)
    }
}

/// Entries are listed and edited by their id.
extension FoodLogEntry: Identifiable {}
