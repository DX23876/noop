import Foundation
import StrandCore
import StrandImport
import WhoopStore

/// The food log on Android (decision 2026-11-08): every `food.*` operation over the shared `FoodLog`,
/// `FoodLibrary` and `FoodCatalog`, so the Kotlin screens only lay out what arrives. Health Connect writing
/// is Android's: operations that add or remove entries return them, and the app writes or deletes the
/// matching records, then reports the record id with `food.setHealthId`.
enum CoreFood {
    struct EntryWire: Codable {
        var id: String, loggedAt: Int, day: String, meal: String?, foodId: String?, name: String, brand: String?
        var grams: Double?, portionLabel: String?, per100g: FoodNutrientValues?, totals: FoodNutrientValues
        var origin: String, recipeId: String?, healthId: String?

        init(_ e: FoodLogEntry) {
            id = e.id; loggedAt = e.loggedAt; day = e.day; meal = e.meal; foodId = e.foodId; name = e.name; brand = e.brand
            grams = e.grams; portionLabel = e.portionLabel; per100g = e.per100g; totals = e.totals
            origin = e.origin.rawValue; recipeId = e.recipeId; healthId = e.healthId
        }
    }
    struct MealWire: Codable { var kind: String; var start: Int; var entries: [EntryWire]; var totals: NutrientAmounts }
    struct DayWire: Codable { var day: String; var meals: [MealWire]; var totals: NutrientAmounts }
    struct RecentWire: Codable { var item: FoodItem; var lastGrams: Double? }

    static func run(_ op: String, args: [String: Any], store: WhoopStore) async -> String {
        func string(_ k: String) -> String { args[k] as? String ?? "" }
        func double(_ k: String) -> Double? { (args[k] as? NSNumber)?.doubleValue }
        func date(_ k: String) -> Date { Date(timeIntervalSince1970: double(k) ?? Date().timeIntervalSince1970) }
        func meal(_ k: String) -> FoodLog.MealKind? { (args[k] as? String).flatMap(FoodLog.MealKind.init(rawValue:)) }
        func item(_ value: Any?) -> FoodItem? {
            guard let value, JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode(FoodItem.self, from: data)
        }
        func entries(_ list: [FoodLogEntry]) -> String { CoreRead.json(["entries": list.map(EntryWire.init)]) }
        let catalog = FoodCatalog.shared

        switch op {
        case "food.prepare":
            // Builds the BLS search file on first use, or after an app update brought a newer table.
            do { try await catalog.prepareBundled(); return #"{"ok":true}"# }
            catch { return #"{"error":"catalogUnavailable"}"# }
        case "food.attribution":
            return CoreRead.json(["bls": FoodCatalog.bundledMeta()])
        case "food.search":
            return CoreRead.json(["items": await FoodLibrary.search(store: store, query: string("query"),
                                                                   limit: (args["limit"] as? Int) ?? 40)])
        case "food.recents":
            let recents = await FoodLibrary.recents(store: store, limit: (args["limit"] as? Int) ?? 30)
            return CoreRead.json(["items": recents.map { RecentWire(item: $0.item, lastGrams: $0.lastGrams) }])
        case "food.favourites":
            return CoreRead.json(["items": await FoodLibrary.favourites(store: store)])
        case "food.setFavourite":
            try? await store.setFoodFavourite(.init(foodId: string("foodId"), name: string("name"),
                                                    addedAt: Int(Date().timeIntervalSince1970)),
                                              on: args["on"] as? Bool ?? true)
            return #"{"ok":true}"#
        case "food.item":
            guard let found = await FoodLibrary.item(store: store, id: string("id")) else { return "null" }
            return CoreRead.json(found)
        case "food.barcode":
            guard let found = await FoodLibrary.item(store: store, barcode: string("code")) else { return "null" }
            return CoreRead.json(found)
        case "food.day":
            let summary = await FoodLog.day(store: store, string("day"))
            return CoreRead.json(DayWire(day: summary.day, meals: summary.meals.map {
                MealWire(kind: $0.kind.rawValue, start: Int($0.start.timeIntervalSince1970),
                         entries: $0.entries.map(EntryWire.init), totals: $0.totals)
            }, totals: summary.totals))
        case "food.logCart":
            // The add sheet's and the coach's cart: every line becomes an entry in one save.
            let at = date("at")
            let lines = (args["items"] as? [[String: Any]]) ?? []
            let made = lines.compactMap { line -> FoodLogEntry? in
                guard let food = item(line["item"]), let grams = (line["grams"] as? NSNumber)?.doubleValue else { return nil }
                return FoodLog.entry(for: food, grams: grams, at: at,
                                     origin: FoodLogEntry.Origin(rawValue: string("origin")) ?? .search,
                                     portionLabel: line["portionLabel"] as? String, meal: meal("meal"))
            }
            guard !made.isEmpty, made.count == lines.count, await FoodLog.save(store: store, made) else {
                return #"{"error":"invalid"}"#
            }
            return entries(made)
        case "food.quick":
            guard let kcal = double("kcal") else { return #"{"error":"invalid"}"# }
            let entry = FoodLog.quickEntry(name: string("name"), kcal: kcal, proteinG: double("proteinG"),
                                           carbsG: double("carbsG"), fatG: double("fatG"), at: date("at"), meal: meal("meal"))
            guard await FoodLog.save(store: store, [entry]) else { return #"{"error":"invalid"}"# }
            return entries([entry])
        case "food.edit":
            guard let old = try? await store.foodLogEntry(id: string("id")) else { return #"{"error":"notFound"}"# }
            let next = FoodLog.edited(old, grams: double("grams"), at: args["at"] != nil ? date("at") : nil,
                                      meal: args["meal"] != nil ? .some(meal("meal")) : nil)
            guard await FoodLog.save(store: store, [next]) else { return #"{"error":"invalid"}"# }
            return CoreRead.json(["entry": EntryWire(next), "previous": EntryWire(old)])
        case "food.delete":
            return CoreRead.json(["removed": await FoodLog.delete(store: store, ids: args["ids"] as? [String] ?? [])
                .map(EntryWire.init)])
        case "food.copy":
            let originals = ((try? await store.foodLogEntries(from: "0000-00-00", to: "9999-99-99")) ?? [])
                .filter { (args["ids"] as? [String] ?? []).contains($0.id) }
            let copies = FoodLog.copies(of: originals, toDays: args["days"] as? [String] ?? [])
            guard !copies.isEmpty, await FoodLog.save(store: store, copies) else { return #"{"error":"invalid"}"# }
            return entries(copies)
        case "food.setHealthId":
            try? await store.setFoodLogHealthId(entryId: string("id"), healthId: args["healthId"] as? String)
            return #"{"ok":true}"#
        case "food.own":
            return CoreRead.json(["items": ((try? await store.customFoods()) ?? []).map(FoodLibrary.item(for:))])
        case "food.saveOwn":
            guard let food = item(args["item"]),
                  let saved = await FoodLibrary.saveOwn(store: store, food,
                                                        origin: CustomFood.Origin(rawValue: string("origin")) ?? .own)
            else { return #"{"error":"invalid"}"# }
            return CoreRead.json(saved)
        case "food.deleteOwn":
            return CoreRead.json(["ok": (try? await store.deleteCustomFood(id: string("id"))) ?? false])
        case "food.recipes":
            return CoreRead.json(["items": ((try? await store.foodRecipes()) ?? []).compactMap(FoodLog.item(for:))])
        case "food.makeRecipe":
            let ids = Set(args["ids"] as? [String] ?? [])
            let chosen = ((try? await store.foodLogEntries(from: "0000-00-00", to: "9999-99-99")) ?? []).filter { ids.contains($0.id) }
            guard let recipe = FoodLog.recipe(name: string("name"), from: chosen, servings: double("servings") ?? 1),
                  (try? await store.saveFoodRecipe(recipe)) == true, let made = FoodLog.item(for: recipe)
            else { return #"{"error":"invalid"}"# }
            return CoreRead.json(made)
        case "food.deleteRecipe":
            return CoreRead.json(["ok": (try? await store.deleteFoodRecipe(id: string("id").replacingOccurrences(of: "recipe:", with: ""))) ?? false])
        case "food.parseLabel":
            let reading = NutritionLabelParser.parse(lines: args["lines"] as? [String] ?? [])
            return CoreRead.json(LabelWire(per100: reading.per100, basis: reading.basis.rawValue,
                                           servingAmount: reading.servingAmount, complete: reading.isComplete))
        case "food.packs":
            return CoreRead.json(["packs": await catalog.installedPacks()])
        case "food.installPack":
            let path = string("path")
            guard path.hasPrefix("/") else { return #"{"error":"invalid"}"# }
            do {
                return CoreRead.json(try await catalog.installPack(archive: URL(fileURLWithPath: path),
                                                                   expectedSha256: string("sha256")))
            } catch let failure as FoodCatalog.Failure {
                return CoreRead.json(["error": failure.rawValue])
            } catch {
                return #"{"error":"invalidArchive"}"#
            }
        case "food.onlineSearch":
            // Only when the wearer chose online search; Kotlin passes the countries it chose.
            do {
                let found = try await FoodOnline.search(string("query"), countries: args["countries"] as? [String] ?? [],
                                                        language: string("language").isEmpty ? "de" : string("language"))
                return CoreRead.json(["items": await FoodLibrary.preferKept(store: store, found)])
            } catch { return #"{"error":"offline"}"# }
        case "food.onlineBarcode":
            do {
                guard let found = try await FoodOnline.product(barcode: string("code"),
                    language: string("language").isEmpty ? "de" : string("language")) else { return "null" }
                return CoreRead.json(await FoodLibrary.preferKept(store: store, [found]).first ?? found)
            } catch { return #"{"error":"offline"}"# }
        case "food.importHealth":
            // Health Connect's daily nutrition per app, as Apple's import resolves it: one app per day, the
            // preferred one when several wrote, a day left out when several did and none is preferred.
            let rows = (args["rows"] as? [[String: Any]]) ?? []
            let preferred = (args["preferred"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let from = string("from"), to = string("to")
            guard !from.isEmpty, !to.isEmpty else { return #"{"error":"invalid"}"# }
            var byDay: [String: [[String: Any]]] = [:]
            for row in rows { if let day = row["day"] as? String { byDay[day, default: []].append(row) } }
            var points: [MetricPoint] = []
            var unresolved: [String] = []
            for (day, candidates) in byDay {
                let chosen = preferred.flatMap { id in candidates.first { $0["source"] as? String == id } }
                    ?? (candidates.count == 1 ? candidates.first : nil)
                guard let chosen else { unresolved.append(day); continue }
                for (key, field) in [(NutritionReads.caloriesKey, "calories"), (NutritionReads.proteinKey, "protein"),
                                     (NutritionReads.carbsKey, "carbs"), (NutritionReads.fatKey, "fat")] {
                    if let value = (chosen[field] as? NSNumber)?.doubleValue, value.isFinite, value > 0 {
                        points.append(MetricPoint(day: day, key: key, value: value))
                    }
                }
            }
            do {
                try await store.replaceMetricSeriesWindow(points, deviceId: MetricResolver.healthConnectSource,
                    keys: [NutritionReads.caloriesKey, NutritionReads.proteinKey, NutritionReads.carbsKey, NutritionReads.fatKey],
                    from: from, to: to)
            } catch { return #"{"error":"storeFailed"}"# }
            struct ImportWire: Encodable { var ok: Bool; var unresolvedDays: [String] }
            return CoreRead.json(ImportWire(ok: true, unresolvedDays: unresolved.sorted()))
        case "food.nutrients":
            // The nutrient card and page: seven days against the EFSA references for this person.
            let references = FoodReference.values(profileSex: string("sex"), age: (args["age"] as? Int) ?? 40,
                                                  weightKg: double("weightKg"), heightCm: double("heightCm"),
                                                  energyKcal: double("energyKcal"))
            return CoreRead.json(await FoodNutrientReport.report(store: store, to: string("day"), references: references))
        case "food.removePack":
            await catalog.removePack(country: string("country"))
            return #"{"ok":true}"#
        default:
            return #"{"error":"unknownOp"}"#
        }
    }

    struct LabelWire: Codable { var per100: [String: Double]; var basis: String; var servingAmount: Double?; var complete: Bool }
}
