import Foundation
import GRDB

// MARK: - Food log (fork decision 2026-11-08)
//
// What the wearer ate, entry by entry, plus the foods, recipes and favourites they keep. Wearer input, not a
// derivation: it cannot be recomputed, so it lives in the store and travels in the `.noopbak` copy of the
// database. The bundled and downloaded food catalogues are NOT here; they are read-only files the app can
// rebuild at any time (`FoodCatalog` in StrandCore).
//
// Every entry keeps a SNAPSHOT of the nutrients it was logged with, so correcting a food later never rewrites
// what was eaten last month. The day totals the energy plan reads are re-banked in the same transaction as
// every change, under `foodLogSourceId` in `metricSeries`, so the totals and the entries cannot disagree.

/// Nutrient amounts keyed by the canonical nutrient names (`FoodNutrient` in StrandCore), stored as JSON.
public typealias FoodNutrientValues = [String: Double]

/// One thing the wearer ate.
public struct FoodLogEntry: Equatable, Sendable {
    /// How the entry was made. Kept for the Health record and for later questions about logging habits.
    public enum Origin: String, Sendable, CaseIterable {
        case search, barcode, label, coach, quick, recipe, copy, online
    }

    public var id: String
    /// When it was eaten (seconds since 1970).
    public var loggedAt: Int
    /// The local calendar day of `loggedAt`, as the day totals are keyed.
    public var day: String
    /// A meal chosen by the wearer; nil groups the entry by its time.
    public var meal: String?
    /// The catalogue or custom food it came from; nil for a quick calorie entry.
    public var foodId: String?
    public var name: String
    public var brand: String?
    /// The amount eaten; nil for a quick calorie entry.
    public var grams: Double?
    public var portionLabel: String?
    /// The food's nutrients per 100 g when it was logged; nil for a quick calorie entry.
    public var per100g: FoodNutrientValues?
    /// This entry's nutrients.
    public var totals: FoodNutrientValues
    public var origin: Origin
    public var recipeId: String?
    /// The record written to Apple Health or Health Connect for this entry, when one was.
    public var healthId: String?
    public var createdAt: Int
    public var updatedAt: Int
    /// Nutrients in this entry that were estimated (borrowed from a similar BLS food), not stated by the source.
    public var estimatedKeys: [String]
    /// The meal photo this entry was logged from, shared by every entry of that meal; nil without one.
    public var photoId: String?

    public init(id: String, loggedAt: Int, day: String, meal: String? = nil, foodId: String?, name: String,
                brand: String? = nil, grams: Double?, portionLabel: String? = nil, per100g: FoodNutrientValues?,
                totals: FoodNutrientValues, origin: Origin, recipeId: String? = nil, healthId: String? = nil,
                createdAt: Int, updatedAt: Int, estimatedKeys: [String] = [], photoId: String? = nil) {
        self.estimatedKeys = estimatedKeys
        self.photoId = photoId
        self.id = id; self.loggedAt = loggedAt; self.day = day; self.meal = meal; self.foodId = foodId
        self.name = name; self.brand = brand; self.grams = grams; self.portionLabel = portionLabel
        self.per100g = per100g; self.totals = totals; self.origin = origin; self.recipeId = recipeId
        self.healthId = healthId; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// A food the wearer keeps: typed in, read from a label, or saved from an online result.
public struct CustomFood: Equatable, Sendable {
    public enum Origin: String, Sendable, CaseIterable {
        case own, label, online, coach
    }

    public var id: String
    public var name: String
    public var brand: String?
    public var barcode: String?
    public var group: String?
    public var nova: Int?
    public var servingG: Double?
    public var servingLabel: String?
    public var per100g: FoodNutrientValues
    public var origin: Origin
    /// The catalogue row it was saved from (for example `off:4000000000017`), when it was.
    public var sourceId: String?
    public var createdAt: Int
    public var updatedAt: Int
    /// The BLS food missing nutrients were borrowed from, and which ones, when the wearer let the coach fill gaps.
    public var estimatedFrom: String?
    public var estimatedKeys: [String]

    public init(id: String, name: String, brand: String? = nil, barcode: String? = nil, group: String? = nil,
                nova: Int? = nil, servingG: Double? = nil, servingLabel: String? = nil, per100g: FoodNutrientValues,
                origin: Origin, sourceId: String? = nil, createdAt: Int, updatedAt: Int,
                estimatedFrom: String? = nil, estimatedKeys: [String] = []) {
        self.estimatedFrom = estimatedFrom; self.estimatedKeys = estimatedKeys
        self.id = id; self.name = name; self.brand = brand; self.barcode = barcode; self.group = group
        self.nova = nova; self.servingG = servingG; self.servingLabel = servingLabel; self.per100g = per100g
        self.origin = origin; self.sourceId = sourceId; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// Foods combined under one name; logged like a food, by the gram.
public struct FoodRecipe: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var foodId: String?
        public var name: String
        public var grams: Double
        public var per100g: FoodNutrientValues

        public init(foodId: String?, name: String, grams: Double, per100g: FoodNutrientValues) {
            self.foodId = foodId; self.name = name; self.grams = grams; self.per100g = per100g
        }
    }

    public var id: String
    public var name: String
    /// How many portions the items make; a portion is `totalGrams / servings`.
    public var servings: Double
    public var items: [Item]
    public var createdAt: Int
    public var updatedAt: Int

    public init(id: String, name: String, servings: Double, items: [Item], createdAt: Int, updatedAt: Int) {
        self.id = id; self.name = name; self.servings = servings; self.items = items
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// A food the wearer starred, by its catalogue or custom id.
public struct FoodFavourite: Equatable, Sendable {
    public var foodId: String
    public var name: String
    public var addedAt: Int

    public init(foodId: String, name: String, addedAt: Int) {
        self.foodId = foodId; self.name = name; self.addedAt = addedAt
    }
}

/// A food recently eaten, for the add sheet's first list.
public struct RecentFood: Equatable, Sendable {
    public var foodId: String
    public var name: String
    public var brand: String?
    public var grams: Double?
    public var per100g: FoodNutrientValues?
    public var lastLoggedAt: Int
    public var timesLogged: Int
}

extension WhoopStore {
    /// The `metricSeries` source the food log's day totals are banked under.
    public static let foodLogSourceId = "food-log"

    /// Canonical nutrient -> the day-total key the energy plan reads (`NutritionReads`). Only these four are
    /// banked: everything else is summed from the entries when a screen asks.
    public static let foodLogDayKeys: [(nutrient: String, key: String)] = [
        ("energy_kcal", "calories_in"), ("protein_g", "protein_g"), ("carbs_g", "carbs_g"), ("fat_g", "fat_g"),
    ]

    static func createFoodLogTables(_ db: Database) throws {
        try db.create(table: "foodCustom") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("name", .text).notNull()
            t.column("brand", .text)
            t.column("barcode", .text)
            t.column("foodGroup", .text)
            t.column("nova", .integer)
            t.column("servingG", .double)
            t.column("servingLabel", .text)
            t.column("per100g", .text).notNull()
            t.column("origin", .text).notNull()
            t.column("sourceId", .text)
            t.column("createdAt", .integer).notNull()
            t.column("updatedAt", .integer).notNull()
            t.column("estimatedFrom", .text)
            t.column("estimatedKeys", .text)
        }
        try db.create(index: "idx_foodCustom_barcode", on: "foodCustom", columns: ["barcode"])
        try db.create(table: "foodLogEntry") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("loggedAt", .integer).notNull()
            t.column("day", .text).notNull()
            t.column("meal", .text)
            t.column("foodId", .text)
            t.column("name", .text).notNull()
            t.column("brand", .text)
            t.column("grams", .double)
            t.column("portionLabel", .text)
            t.column("per100g", .text)
            t.column("totals", .text).notNull()
            t.column("origin", .text).notNull()
            t.column("recipeId", .text)
            t.column("healthId", .text)
            t.column("createdAt", .integer).notNull()
            t.column("updatedAt", .integer).notNull()
            t.column("estimatedKeys", .text)
        }
        try db.create(index: "idx_foodLogEntry_day", on: "foodLogEntry", columns: ["day", "loggedAt"])
        try db.create(index: "idx_foodLogEntry_foodId", on: "foodLogEntry", columns: ["foodId", "loggedAt"])
        try db.create(table: "foodRecipe") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("name", .text).notNull()
            t.column("servings", .double).notNull()
            t.column("createdAt", .integer).notNull()
            t.column("updatedAt", .integer).notNull()
        }
        try db.create(table: "foodRecipeItem") { t in
            t.column("recipeId", .text).notNull()
            t.column("position", .integer).notNull()
            t.column("foodId", .text)
            t.column("name", .text).notNull()
            t.column("grams", .double).notNull()
            t.column("per100g", .text).notNull()
            t.primaryKey(["recipeId", "position"])
        }
        try db.create(table: "foodFavourite") { t in
            t.column("foodId", .text).notNull().primaryKey()
            t.column("name", .text).notNull()
            t.column("addedAt", .integer).notNull()
        }
    }

    // MARK: - Entries

    /// Stores entries (new or edited) and re-banks the totals of every day they touch, the days they moved
    /// away from included, in one transaction. Returns false and writes nothing when an entry is not a real
    /// meal: an empty name, a non-positive or absurd amount, or a non-finite or negative nutrient.
    @discardableResult
    public func saveFoodLogEntries(_ entries: [FoodLogEntry]) async throws -> Bool {
        guard !entries.isEmpty, entries.allSatisfy(Self.isValid) else { return false }
        try syncWrite { db in
            var days = Set(entries.map(\.day))
            let ids = entries.map(\.id)
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            days.formUnion(try String.fetchAll(db, sql: "SELECT day FROM foodLogEntry WHERE id IN (\(placeholders))",
                                               arguments: StatementArguments(ids)))
            for entry in entries {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO foodLogEntry
                      (id, loggedAt, day, meal, foodId, name, brand, grams, portionLabel, per100g, totals, origin,
                       recipeId, healthId, createdAt, updatedAt, estimatedKeys, photoId)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        entry.id, entry.loggedAt, entry.day, entry.meal, entry.foodId, entry.name, entry.brand,
                        entry.grams, entry.portionLabel, entry.per100g.map(Self.encodeNutrients),
                        Self.encodeNutrients(entry.totals), entry.origin.rawValue, entry.recipeId, entry.healthId,
                        entry.createdAt, entry.updatedAt, Self.encodeKeys(entry.estimatedKeys), entry.photoId])
            }
            for day in days { try Self.rebankFoodLogDay(day, in: db) }
        }
        return true
    }

    /// Removes entries and re-banks their days. Returns the removed entries, so the caller can delete the
    /// Health records they carried.
    @discardableResult
    public func deleteFoodLogEntries(ids: [String]) async throws -> [FoodLogEntry] {
        guard !ids.isEmpty else { return [] }
        return try syncWrite { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let removed = try Row.fetchAll(db, sql: "SELECT * FROM foodLogEntry WHERE id IN (\(placeholders))",
                                           arguments: StatementArguments(ids)).compactMap(Self.decodeEntry)
            try db.execute(sql: "DELETE FROM foodLogEntry WHERE id IN (\(placeholders))", arguments: StatementArguments(ids))
            for day in Set(removed.map(\.day)) { try Self.rebankFoodLogDay(day, in: db) }
            return removed
        }
    }

    /// The photo ids among `ids` that some entry still names, so a photo is removed only with its last entry.
    public func foodPhotoIdsInUse(_ ids: Set<String>) async throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try syncRead { db in
            let list = Array(ids)
            let placeholders = Array(repeating: "?", count: list.count).joined(separator: ",")
            return Set(try String.fetchAll(db, sql: "SELECT DISTINCT photoId FROM foodLogEntry WHERE photoId IN (\(placeholders))",
                                           arguments: StatementArguments(list)))
        }
    }

    /// Every photo id an entry names, for clearing photos no entry kept (a cart that was never saved).
    public func allFoodPhotoIds() async throws -> Set<String> {
        try syncRead { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT photoId FROM foodLogEntry WHERE photoId IS NOT NULL"))
        }
    }

    /// Records the Health record written for an entry (nil after it was removed there).
    public func setFoodLogHealthId(entryId: String, healthId: String?) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE foodLogEntry SET healthId = ? WHERE id = ?", arguments: [healthId, entryId])
        }
    }

    /// Entries on days in [from, to], in eating order.
    public func foodLogEntries(from: String, to: String) async throws -> [FoodLogEntry] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodLogEntry WHERE day >= ? AND day <= ? ORDER BY loggedAt, createdAt, id
                """, arguments: [from, to]).compactMap(Self.decodeEntry)
        }
    }

    /// The entries with these ids, in eating order.
    public func foodLogEntries(ids: [String]) async throws -> [FoodLogEntry] {
        guard !ids.isEmpty else { return [] }
        return try syncRead { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return try Row.fetchAll(db, sql: "SELECT * FROM foodLogEntry WHERE id IN (\(placeholders)) ORDER BY loggedAt, createdAt, id",
                                    arguments: StatementArguments(ids)).compactMap(Self.decodeEntry)
        }
    }

    public func foodLogEntry(id: String) async throws -> FoodLogEntry? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM foodLogEntry WHERE id = ?", arguments: [id]).flatMap(Self.decodeEntry)
        }
    }

    /// Entries that carry a Health record, for the writer's reconciliation.
    public func foodLogEntriesWithHealthIds(from: String, to: String) async throws -> [FoodLogEntry] {
        try await foodLogEntries(from: from, to: to).filter { $0.healthId != nil }
    }

    /// Foods eaten most recently, one row per food, newest first. Quick calorie entries have no food and are
    /// left out.
    public func recentFoods(limit: Int) async throws -> [RecentFood] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT e.foodId, e.name, e.brand, e.grams, e.per100g, e.loggedAt, c.n FROM foodLogEntry e
                JOIN (SELECT foodId, MAX(loggedAt) AS last, COUNT(*) AS n FROM foodLogEntry
                      WHERE foodId IS NOT NULL GROUP BY foodId) c
                  ON c.foodId = e.foodId AND c.last = e.loggedAt
                GROUP BY e.foodId ORDER BY e.loggedAt DESC LIMIT ?
                """, arguments: [max(0, limit)]).map { row in
                    RecentFood(foodId: row["foodId"], name: row["name"], brand: row["brand"], grams: row["grams"],
                               per100g: (row["per100g"] as String?).flatMap(Self.decodeNutrients),
                               lastLoggedAt: row["loggedAt"], timesLogged: row["n"])
                }
        }
    }

    /// Sums every entry of a day into the banked totals; an empty day loses its rows.
    static func rebankFoodLogDay(_ day: String, in db: Database) throws {
        let keys = foodLogDayKeys.map(\.key)
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        var arguments: [DatabaseValueConvertible?] = [foodLogSourceId, day]
        arguments.append(contentsOf: keys)
        try db.execute(sql: """
            DELETE FROM metricSeries WHERE deviceId = ? AND day = ? AND key IN (\(placeholders))
            """, arguments: StatementArguments(arguments))
        let totals = try String.fetchAll(db, sql: "SELECT totals FROM foodLogEntry WHERE day = ?", arguments: [day])
        guard !totals.isEmpty else { return }
        var sums: [String: Double] = [:]
        var present: Set<String> = []
        for json in totals {
            for (nutrient, value) in decodeNutrients(json) ?? [:] {
                sums[nutrient, default: 0] += value
                present.insert(nutrient)
            }
        }
        // Calories are always banked for a logged day (a logged day of only water is a real zero); the macros
        // only when some entry knew them, so an unknown stays unknown.
        let rows = foodLogDayKeys.compactMap { pair -> MetricPoint? in
            if pair.nutrient == "energy_kcal" { return MetricPoint(day: day, key: pair.key, value: sums[pair.nutrient] ?? 0) }
            guard present.contains(pair.nutrient) else { return nil }
            return MetricPoint(day: day, key: pair.key, value: sums[pair.nutrient] ?? 0)
        }
        _ = try upsertMetricSeries(rows, deviceId: foodLogSourceId, in: db)
    }

    static func isValid(_ entry: FoodLogEntry) -> Bool {
        let nameOK = !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let gramsOK = entry.grams.map { $0.isFinite && $0 > 0 && $0 <= 10_000 } ?? true
        let values = Array(entry.totals.values) + Array((entry.per100g ?? [:]).values)
        let dayOK = entry.day.count == 10
        return nameOK && gramsOK && dayOK && values.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 1_000_000 }
            && (entry.totals["energy_kcal"].map { $0 < 50_000 } ?? true)
    }

    fileprivate static func decodeEntry(_ row: Row) -> FoodLogEntry? {
        guard let origin = FoodLogEntry.Origin(rawValue: row["origin"]),
              let totals = decodeNutrients(row["totals"]) else { return nil }
        return FoodLogEntry(
            id: row["id"], loggedAt: row["loggedAt"], day: row["day"], meal: row["meal"], foodId: row["foodId"],
            name: row["name"], brand: row["brand"], grams: row["grams"], portionLabel: row["portionLabel"],
            per100g: (row["per100g"] as String?).flatMap(decodeNutrients), totals: totals, origin: origin,
            recipeId: row["recipeId"], healthId: row["healthId"], createdAt: row["createdAt"], updatedAt: row["updatedAt"],
            estimatedKeys: decodeKeys(row["estimatedKeys"]), photoId: row["photoId"])
    }

    // MARK: - Custom foods

    @discardableResult
    public func saveCustomFood(_ food: CustomFood) async throws -> Bool {
        guard !food.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              food.per100g.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              food.servingG.map({ $0.isFinite && $0 > 0 }) ?? true else { return false }
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO foodCustom
                  (id, name, brand, barcode, foodGroup, nova, servingG, servingLabel, per100g, origin, sourceId,
                   createdAt, updatedAt, estimatedFrom, estimatedKeys)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    food.id, food.name, food.brand, food.barcode, food.group, food.nova, food.servingG,
                    food.servingLabel, Self.encodeNutrients(food.per100g), food.origin.rawValue, food.sourceId,
                    food.createdAt, food.updatedAt, food.estimatedFrom, Self.encodeKeys(food.estimatedKeys)])
        }
        return true
    }

    @discardableResult
    public func deleteCustomFood(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM foodCustom WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    public func customFoods() async throws -> [CustomFood] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM foodCustom ORDER BY name COLLATE NOCASE, id")
                .compactMap(Self.decodeCustomFood)
        }
    }

    public func customFood(id: String) async throws -> CustomFood? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM foodCustom WHERE id = ?", arguments: [id]).flatMap(Self.decodeCustomFood)
        }
    }

    /// The newest custom food carrying this barcode.
    public func customFood(barcode: String) async throws -> CustomFood? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM foodCustom WHERE barcode = ? ORDER BY updatedAt DESC LIMIT 1",
                             arguments: [barcode]).flatMap(Self.decodeCustomFood)
        }
    }

    fileprivate static func decodeCustomFood(_ row: Row) -> CustomFood? {
        guard let origin = CustomFood.Origin(rawValue: row["origin"]),
              let per100g = decodeNutrients(row["per100g"]) else { return nil }
        return CustomFood(id: row["id"], name: row["name"], brand: row["brand"], barcode: row["barcode"],
                          group: row["foodGroup"], nova: row["nova"], servingG: row["servingG"],
                          servingLabel: row["servingLabel"], per100g: per100g, origin: origin,
                          sourceId: row["sourceId"], createdAt: row["createdAt"], updatedAt: row["updatedAt"],
                          estimatedFrom: row["estimatedFrom"], estimatedKeys: decodeKeys(row["estimatedKeys"]))
    }

    // MARK: - Recipes

    @discardableResult
    public func saveFoodRecipe(_ recipe: FoodRecipe) async throws -> Bool {
        guard !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !recipe.items.isEmpty,
              recipe.servings.isFinite, recipe.servings > 0,
              recipe.items.allSatisfy({ $0.grams.isFinite && $0.grams > 0 && $0.per100g.values.allSatisfy(\.isFinite) })
        else { return false }
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO foodRecipe (id, name, servings, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?)
                """, arguments: [recipe.id, recipe.name, recipe.servings, recipe.createdAt, recipe.updatedAt])
            try db.execute(sql: "DELETE FROM foodRecipeItem WHERE recipeId = ?", arguments: [recipe.id])
            for (position, item) in recipe.items.enumerated() {
                try db.execute(sql: """
                    INSERT INTO foodRecipeItem (recipeId, position, foodId, name, grams, per100g) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [recipe.id, position, item.foodId, item.name, item.grams,
                                     Self.encodeNutrients(item.per100g)])
            }
        }
        return true
    }

    @discardableResult
    public func deleteFoodRecipe(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM foodRecipeItem WHERE recipeId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM foodRecipe WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    public func foodRecipes() async throws -> [FoodRecipe] {
        try syncRead { db in
            let items = try Row.fetchAll(db, sql: "SELECT * FROM foodRecipeItem ORDER BY recipeId, position")
            var byRecipe: [String: [FoodRecipe.Item]] = [:]
            for row in items {
                guard let per100g = Self.decodeNutrients(row["per100g"]) else { continue }
                byRecipe[row["recipeId"], default: []].append(
                    .init(foodId: row["foodId"], name: row["name"], grams: row["grams"], per100g: per100g))
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM foodRecipe ORDER BY name COLLATE NOCASE, id").map { row in
                let id: String = row["id"]
                return FoodRecipe(id: id, name: row["name"], servings: row["servings"], items: byRecipe[id] ?? [],
                                  createdAt: row["createdAt"], updatedAt: row["updatedAt"])
            }
        }
    }

    // MARK: - Favourites

    public func setFoodFavourite(_ favourite: FoodFavourite, on: Bool) async throws {
        try syncWrite { db in
            if on {
                try db.execute(sql: "INSERT OR REPLACE INTO foodFavourite (foodId, name, addedAt) VALUES (?, ?, ?)",
                               arguments: [favourite.foodId, favourite.name, favourite.addedAt])
            } else {
                try db.execute(sql: "DELETE FROM foodFavourite WHERE foodId = ?", arguments: [favourite.foodId])
            }
        }
    }

    public func foodFavourites() async throws -> [FoodFavourite] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM foodFavourite ORDER BY addedAt DESC, foodId").map {
                FoodFavourite(foodId: $0["foodId"], name: $0["name"], addedAt: $0["addedAt"])
            }
        }
    }

    // MARK: - Nutrient JSON

    /// Sorted keys and plain numbers, so the same values always encode to the same text.
    static func encodeNutrients(_ values: FoodNutrientValues) -> String {
        let finite = values.filter { $0.value.isFinite }
        let data = (try? JSONSerialization.data(withJSONObject: finite, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Nil for an empty list, so entries without estimates store nothing.
    static func encodeKeys(_ keys: [String]) -> String? {
        guard !keys.isEmpty, let data = try? JSONSerialization.data(withJSONObject: keys.sorted()) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeKeys(_ json: String?) -> [String] {
        guard let json, let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String] else { return [] }
        return list
    }

    static func decodeNutrients(_ json: String?) -> FoodNutrientValues? {
        guard let json, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        return object.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
}
