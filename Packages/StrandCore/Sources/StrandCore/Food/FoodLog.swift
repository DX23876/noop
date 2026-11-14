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

    /// The calories the energy plan counts for `day` when they do NOT come from the food log (a typed day value,
    /// Health, Health Connect or a CSV import win over or replace it), so the Food page can say so instead of
    /// showing a second, different intake (one fact, one readout).
    public static func otherIntake(store: WhoopStore, _ day: String) async -> (kcal: Double, source: NutritionDay.Source)? {
        guard let resolved = await NutritionReads.nutritionByDay(store: store, from: day, to: day)[day],
              let kcal = resolved.calories, let source = resolved.caloriesSource, source != .foodLog else { return nil }
        return (kcal, source)
    }

    public static func day(store: WhoopStore, catalog: FoodCatalog = .shared, _ day: String) async -> DaySummary {
        let entries = await named((try? await store.foodLogEntries(from: day, to: day)) ?? [], catalog: catalog)
        return DaySummary(day: day, entries: entries, meals: meals(entries),
                          totals: .sum(entries.map { NutrientAmounts(stored: $0.totals) }))
    }

    /// BLS entries under the catalogue's name in the app language, whichever language they were logged in; an
    /// entry the catalogue cannot find (not prepared yet, or an id it no longer has) keeps its stored name.
    public static func named(_ entries: [FoodLogEntry], catalog: FoodCatalog = .shared) async -> [FoodLogEntry] {
        var names: [String: String] = [:]
        var out = entries
        for index in out.indices {
            guard let id = out[index].foodId, id.hasPrefix("bls:") else { continue }
            if names[id] == nil { names[id] = await catalog.name(id: id) }
            if let name = names[id] { out[index].name = name }
        }
        return out
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
                             portionLabel: String? = nil, meal: MealKind? = nil, photoId: String? = nil,
                             id: String = UUID().uuidString, now: Date = Date()) -> FoodLogEntry {
        let stamp = Int(now.timeIntervalSince1970)
        return FoodLogEntry(
            id: id, loggedAt: Int(at.timeIntervalSince1970), day: StoreReader.localDayKey(at), meal: meal?.rawValue,
            foodId: item.id, name: item.name, brand: item.brand, grams: grams, portionLabel: portionLabel,
            per100g: item.per100g.stored, totals: item.per100g.scaled(toGrams: grams).stored, origin: origin,
            recipeId: item.source == .recipe ? String(item.id.dropFirst("recipe:".count)) : nil,
            createdAt: stamp, updatedAt: stamp, estimatedKeys: item.estimatedKeys ?? [], photoId: photoId)
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

    /// The same entry with a corrected product's values: the amount, the time and the meal stay as logged, the
    /// per-100 g snapshot, the totals, the name and the marks follow the product. Nil when there is nothing to
    /// restate (a quick calorie figure has no snapshot) and when the values already match, so a correction that
    /// changed nothing writes nothing.
    public static func restated(_ entry: FoodLogEntry, from item: FoodItem, now: Date = Date()) -> FoodLogEntry? {
        guard let grams = entry.grams, entry.per100g != nil else { return nil }
        var next = entry
        next.name = item.name
        next.brand = item.brand
        next.per100g = item.per100g.stored
        next.totals = item.per100g.scaled(toGrams: grams).stored
        next.estimatedKeys = item.estimatedKeys ?? []
        guard next != entry else { return nil }
        next.updatedAt = Int(now.timeIntervalSince1970)
        return next
    }

    /// The entries logged from any of `foodIds` within the last `days` days, newest first: what a correction to
    /// that product may be applied to. One product reaches the log under several ids (the catalogue row it came
    /// from, the wearer's own copy of it), so every id is asked for at once. Read over the day window, so the
    /// rows are bounded by the window and not by the length of the log.
    public static func recentEntries(store: WhoopStore, foodIds: Set<String>, days: Int = 14,
                                     now: Date = Date()) async -> [FoodLogEntry] {
        guard !foodIds.isEmpty, days > 0 else { return [] }
        let from = StoreReader.localDayKey(now.addingTimeInterval(-Double(days - 1) * 86_400))
        let entries = (try? await store.foodLogEntries(from: from, to: StoreReader.localDayKey(now))) ?? []
        return entries.filter { entry in
            entry.grams != nil && entry.per100g != nil && entry.foodId.map(foodIds.contains) == true
        }
        .sorted { $0.loggedAt > $1.loggedAt }
    }

    @discardableResult
    public static func save(store: WhoopStore, _ entries: [FoodLogEntry]) async -> Bool {
        (try? await store.saveFoodLogEntries(entries)) ?? false
    }

    @discardableResult
    public static func delete(store: WhoopStore, ids: [String],
                              photos: FoodPhotoStore? = FoodPhotoStore.appDefault) async -> [FoodLogEntry] {
        let removed = (try? await store.deleteFoodLogEntries(ids: ids)) ?? []
        // A photo goes with the last entry that names it; copies on other days keep it alive.
        let named = Set(removed.compactMap(\.photoId))
        if let photos, !named.isEmpty, let inUse = try? await store.foodPhotoIdsInUse(named) {
            for id in named.subtracting(inUse) { photos.remove(id) }
        }
        return removed
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
        let customs = (try? await store.customFoods()) ?? []
        let own = customs.map(item(for:)).filter { matches($0.name + " " + ($0.brand ?? "")) }
        let recipes = ((try? await store.foodRecipes()) ?? []).compactMap(FoodLog.item(for:)).filter { matches($0.name) }
        // A product kept as the wearer's own (often with its gaps filled) replaces its catalogue row.
        let kept = Set(customs.compactMap(\.sourceId))
        let catalogue = await catalog.search(query, limit: limit).filter { !kept.contains($0.id) }
        var seen = Set<String>()
        return (recipes + own + catalogue).filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    /// Foods eaten recently, as they were logged last time (their last amount is in `RecentFood.grams`).
    public static func recents(store: WhoopStore, catalog: FoodCatalog = .shared,
                               limit: Int = 30) async -> [(item: FoodItem, lastGrams: Double?)] {
        var out: [(item: FoodItem, lastGrams: Double?)] = []
        for recent in (try? await store.recentFoods(limit: limit)) ?? [] {
            guard let per100g = recent.per100g else { continue }
            let source: FoodItem.Source = recent.foodId.hasPrefix("bls:") ? .bls
                : recent.foodId.hasPrefix("off:") ? .off : recent.foodId.hasPrefix("recipe:") ? .recipe : .own
            // A BLS food under its name in the app language, as search and the day's meals show it.
            let name = source == .bls ? (await catalog.name(id: recent.foodId) ?? recent.name) : recent.name
            out.append((FoodItem(id: recent.foodId, source: source, name: name, brand: recent.brand,
                                 per100g: NutrientAmounts(stored: per100g)), recent.grams))
        }
        return out
    }

    public static func favourites(store: WhoopStore, catalog: FoodCatalog = .shared) async -> [FoodItem] {
        let own = (try? await store.customFoods()) ?? []
        let byId = Dictionary(own.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let bySource = keptBySource(own)
        var out: [FoodItem] = []
        for favourite in (try? await store.foodFavourites()) ?? [] {
            if let food = byId[favourite.foodId] ?? bySource[favourite.foodId] { out.append(item(for: food)) }
            else if let found = await item(store: store, catalog: catalog, id: favourite.foodId) { out.append(found) }
        }
        return out
    }

    /// The newest own food per catalogue id it was kept from.
    static func keptBySource(_ own: [CustomFood]) -> [String: CustomFood] {
        var out: [String: CustomFood] = [:]
        for food in own {
            if let source = food.sourceId, (out[source]?.updatedAt ?? -1) < food.updatedAt { out[source] = food }
        }
        return out
    }

    public static func item(store: WhoopStore, catalog: FoodCatalog = .shared, id: String) async -> FoodItem? {
        if id.hasPrefix("own:"), let food = try? await store.customFood(id: id) { return item(for: food) }
        // A catalogue product the wearer kept (with its filled nutrients) opens as the kept one, wherever the id
        // comes from: a favourite, an old entry, the coach.
        if let kept = await keptVersion(store: store, of: id) { return kept }
        if id.hasPrefix("recipe:") {
            let recipeId = String(id.dropFirst("recipe:".count))
            return ((try? await store.foodRecipes()) ?? []).first { $0.id == recipeId }.flatMap(FoodLog.item(for:))
        }
        return await catalog.item(id: id)
    }

    /// The wearer's own food saved from catalogue or online row `id`, newest first.
    public static func keptVersion(store: WhoopStore, of id: String) async -> FoodItem? {
        ((try? await store.customFoods()) ?? []).filter { $0.sourceId == id }.max { $0.updatedAt < $1.updatedAt }
            .map(item(for:))
    }

    /// Online results with every product the wearer already keeps swapped for the kept version.
    public static func preferKept(store: WhoopStore, _ items: [FoodItem]) async -> [FoodItem] {
        let bySource = keptBySource((try? await store.customFoods()) ?? [])
        return items.map { bySource[$0.id].map(item(for:)) ?? $0 }
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
        // Updating an own food keeps where it came from and when; a placeholder id ("own:new") is no source.
        let existing = food.source == .own ? try? await store.customFood(id: food.id) : nil
        let source = food.source == .own || food.id.hasPrefix("own:") ? existing?.sourceId : food.id
        let custom = CustomFood(id: id, name: food.name, brand: food.brand, barcode: food.barcode, group: food.group,
                                nova: food.nova, servingG: food.servingG, servingLabel: food.servingLabel,
                                per100g: food.per100g.stored, origin: existing?.origin ?? origin,
                                sourceId: source, createdAt: existing?.createdAt ?? stamp, updatedAt: stamp,
                                estimatedFrom: food.estimatedFrom, estimatedKeys: food.estimatedKeys ?? [])
        guard (try? await store.saveCustomFood(custom)) == true else { return nil }
        return item(for: custom)
    }

    /// The wearer's own copy of a catalogue or online row, by its source id or by its barcode. Nil when there is
    /// none yet.
    public static func ownCopy(store: WhoopStore, of item: FoodItem) async -> FoodItem? {
        if item.source == .own { return item }
        if let kept = await keptVersion(store: store, of: item.id) { return kept }
        guard let barcode = item.barcode else { return nil }
        for code in FoodCatalog.barcodeVariants(barcode) {
            if let food = try? await store.customFood(barcode: code) { return self.item(for: food) }
        }
        return nil
    }

    /// Where a correction to `item` is written: the wearer's own copy of that row when one already exists, so
    /// correcting the same product twice does not leave two own foods behind. Only the identity moves; the values
    /// passed in are the corrected ones and stay untouched.
    public static func correctionTarget(store: WhoopStore, for item: FoodItem) async -> FoodItem {
        guard item.source != .own, let own = await ownCopy(store: store, of: item) else { return item }
        var next = item
        next.id = own.id
        next.source = .own
        return next
    }

    /// Every id one product reaches the food log under: the catalogue or online row it was found as, and the
    /// wearer's own copy of it. A correction has to find its entries under both.
    public static func logIds(store: WhoopStore, for item: FoodItem) async -> Set<String> {
        var ids: Set<String> = [item.id]
        if item.source == .own, let food = try? await store.customFood(id: item.id), let source = food.sourceId {
            ids.insert(source)
        }
        if let own = await ownCopy(store: store, of: item) { ids.insert(own.id) }
        return ids
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
