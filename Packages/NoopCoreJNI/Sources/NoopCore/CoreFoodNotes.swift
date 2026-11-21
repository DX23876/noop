import Foundation
import StrandCore
import StrandAnalytics
import WhoopStore

/// The food log's favourites, notes, goal state, badges and reminder content on Android (owner, 2026-11-21), over
/// the same core types the iPhone reads (`FoodSavedMeal`, `FoodQuality`, `FoodGoalState`, `FoodBadges`,
/// `FoodNotice`), so the two platforms cannot show different notes for the same log.
enum CoreFoodNotes {
    struct MealItemWire: Codable { var foodId: String?; var name: String; var grams: Double; var per100g: FoodNutrientValues }
    struct MealWire: Encodable {
        var id: String, name: String, items: [MealItemWire], kcal: Double, motif: String?, createdAt: Int, updatedAt: Int
        init(_ meal: FoodSavedMeal) {
            id = meal.id; name = meal.name; createdAt = meal.createdAt; updatedAt = meal.updatedAt
            items = meal.items.map { MealItemWire(foodId: $0.foodId, name: $0.name, grams: $0.grams, per100g: $0.per100g) }
            kcal = FoodLog.kcal(of: meal)
            var byMotif: [FoodGroupMotif: Double] = [:]
            for item in meal.items {
                if let m = FoodGroupMotif.forFoodId(item.foodId) {
                    byMotif[m, default: 0] += (item.per100g["energy_kcal"] ?? 0) * item.grams / 100
                }
            }
            motif = FoodGroupMotif.allCases.filter { byMotif[$0] != nil }.max { (byMotif[$0] ?? 0) < (byMotif[$1] ?? 0) }?.rawValue
        }
    }
    struct GoalWire: Encodable { var energy: String; var ratio: Double; var proteinMet: Bool?; var carbsWithinCap: Bool? }
    struct EarnedWire: Encodable { var key: String; var day: String }

    /// The badge's stable key, the same one iOS keeps for "already celebrated".
    static func key(_ badge: FoodBadges.Badge) -> String {
        switch badge {
        case .firstFullWeek: "firstFullWeek"
        case .days30: "days30"
        case .days100: "days100"
        case .goodWeek: "goodWeek"
        case .goodMonth: "goodMonth"
        case .habit(let c): "habit." + c.rawValue
        }
    }

    /// Nil when `op` is not one of these, so `CoreFood.run` goes on.
    static func run(_ op: String, args: [String: Any], store: WhoopStore) async -> String? {
        func string(_ k: String) -> String { args[k] as? String ?? "" }
        func double(_ k: String) -> Double? { (args[k] as? NSNumber)?.doubleValue }
        func at() -> Date { Date(timeIntervalSince1970: double("at") ?? Date().timeIntervalSince1970) }

        switch op {
        case "food.meals":
            return CoreRead.json(["meals": ((try? await store.foodMeals()) ?? []).map(MealWire.init)])
        case "food.saveMeal":
            // From the builder (`items`), from logged entries (`entryIds`) or from the cart (`cart`).
            let name = string("name")
            var meal: FoodSavedMeal?
            if let ids = args["entryIds"] as? [String] {
                meal = FoodLog.savedMeal(name: name, from: (try? await store.foodLogEntries(ids: ids)) ?? [])
            } else if let cart = args["cart"] as? [[String: Any]] {
                var foods: [(item: FoodItem, grams: Double)] = []
                for line in cart {
                    guard let value = line["item"], JSONSerialization.isValidJSONObject(value),
                          let data = try? JSONSerialization.data(withJSONObject: value),
                          var food = try? JSONDecoder().decode(FoodItem.self, from: data),
                          let grams = (line["grams"] as? NSNumber)?.doubleValue else { continue }
                    if food.source == .online, let kept = await FoodLibrary.saveOwn(store: store, food, origin: .online) { food = kept }
                    foods.append((food, grams))
                }
                meal = FoodLog.savedMeal(name: name, foods: foods)
            } else if let raw = args["items"] as? [[String: Any]] {
                let items = raw.compactMap { item -> FoodRecipe.Item? in
                    guard let grams = (item["grams"] as? NSNumber)?.doubleValue,
                          let per100g = item["per100g"] as? [String: NSNumber] else { return nil }
                    return .init(foodId: item["foodId"] as? String, name: item["name"] as? String ?? "", grams: grams,
                                 per100g: per100g.mapValues(\.doubleValue))
                }
                let id = (args["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
                meal = FoodLog.savedMeal(name: name, items: items, id: id, createdAt: (args["createdAt"] as? NSNumber)?.intValue)
            }
            guard let meal, (try? await store.saveFoodMeal(meal)) == true else { return #"{"error":"invalid"}"# }
            return CoreRead.json(MealWire(meal))
        case "food.deleteMeal":
            return CoreRead.json(["ok": (try? await store.deleteFoodMeal(id: string("id"))) ?? false])
        case "food.logMeal":
            guard var meal = ((try? await store.foodMeals()) ?? []).first(where: { $0.id == string("id") }) else {
                return #"{"error":"notFound"}"#
            }
            let when = at()
            let made = FoodLog.entries(of: meal, at: when, kind: FoodLog.MealKind.around(when))
            guard await FoodLog.save(store: store, made) else { return #"{"error":"invalid"}"# }
            meal.updatedAt = Int(Date().timeIntervalSince1970)
            try? await store.saveFoodMeal(meal)
            return CoreRead.json(["entries": made.map(CoreFood.EntryWire.init)])
        case "food.quality", "food.recap", "food.evening":
            return await quality(op, args: args, store: store)
        case "food.reminderTimes":
            // Morning half an hour after the wake time, evening three hours before bed and never before 17:00.
            let wake = (args["wakeMinutes"] as? NSNumber)?.intValue ?? 7 * 60
            let need = (args["sleepNeedMinutes"] as? NSNumber)?.intValue ?? 8 * 60
            let bed = (wake - need + 24 * 60) % (24 * 60)
            let evening = FoodNotice.eveningTime(usualBedtime: DateComponents(hour: bed / 60, minute: bed % 60))
            return CoreRead.json(["morning": min(wake + 30, 23 * 60), "evening": (evening.hour ?? 20) * 60 + (evening.minute ?? 0)])
        case "food.mealAround":
            return CoreRead.json(["kind": FoodLog.MealKind.around(at()).rawValue])
        case "food.motifs":
            // The still life for each food of a list, by the one resolver the meal cards use (`FoodGroupMotif`).
            var out: [String: String] = [:]
            for row in (args["items"] as? [[String: Any]]) ?? [] {
                guard let id = row["id"] as? String else { continue }
                if let motif = FoodGroupMotif.forFoodId(id) ?? FoodGroupMotif.forGroup(row["group"] as? String) {
                    out[id] = motif.rawValue
                }
            }
            return CoreRead.json(out)
        case "food.overWarning":
            let kcal = FoodGoalState.overWarning(dayKcal: double("dayKcal") ?? 0, adding: double("adding") ?? 0,
                                                 goalKcal: double("goalKcal") ?? 0, losing: args["losing"] as? Bool ?? false)
            return CoreRead.json(["kcal": kcal])
        default:
            return nil
        }
    }

    /// The notes, goal state and badges of a day, tomorrow morning's look back, or tonight's gap.
    static func quality(_ op: String, args: [String: Any], store: WhoopStore) async -> String {
        func string(_ k: String) -> String { args[k] as? String ?? "" }
        func double(_ k: String) -> Double? { (args[k] as? NSNumber)?.doubleValue }
        let today = string("today")
        let day = args["day"] as? String ?? today
        let all = (try? await store.foodLogEntries(from: "2000-01-01", to: today)) ?? []
        var facts: [String: FoodScore.FoodFacts] = [:]
        for id in Set(all.compactMap(\.foodId)) where !id.hasPrefix("bls:") {
            if let item = await FoodLibrary.item(store: store, id: id) { facts[id] = .init(group: item.group, nova: item.nova) }
        }
        let sex = string("sex").lowercased()
        let male: Bool? = sex == "male" ? true : sex == "female" ? false : nil
        let options = FoodScore.Options.forDiet(DietForm(rawValue: string("dietForm")))
        let profile = UserProfile(weightKg: double("weightKg") ?? 70, heightCm: double("heightCm") ?? 170,
                                  age: double("age") ?? 30, sex: sex)
        let floor = FoodGoalState.floorKcal(basalKcal: Calories.bmrKcalPerDay(profile: profile), male: male)
        let goals = double("goalKcal").map {
            FoodGoalState.Goals(kcal: $0, proteinG: double("proteinG"), carbCapG: DietForm(rawValue: string("dietForm"))?.carbCapG,
                                floorKcal: floor)
        }

        switch op {
        case "food.evening":
            let eaten = all.filter { $0.day == today }
            let gap = FoodNotice.eveningGap(proteinEatenG: eaten.reduce(0) { $0 + ($1.totals["protein_g"] ?? 0) },
                                            proteinGoalG: double("proteinG"),
                                            vegetableGrams: FoodNotice.vegetableGrams(eaten, facts: facts))
            return CoreRead.json(["proteinG": gap?.proteinG, "vegetablePortions": gap?.vegetablePortions])
        case "food.recap":
            guard let tomorrow = FoodQuality.shifted(today, by: 1, calendar: .current) else { return "null" }
            let kind = FoodNotice.morningKind(today: tomorrow)
            var note: FoodQuality.Note?, previous: FoodQuality.Note?, goal: FoodGoalState.Energy?
            if kind == .day {
                let usual = FoodQuality.usualKcal(entries: all, before: today) ?? goals?.kcal
                note = try? FoodQuality.day(today, entries: all, facts: facts, male: male, options: options, usualKcal: usual,
                                            today: tomorrow).get()
                let eaten = all.filter { $0.day == today }
                let totals = NutrientAmounts.sum(eaten.map { NutrientAmounts(stored: $0.totals) })
                if !eaten.isEmpty, let goals {
                    goal = FoodGoalState.day(kcal: totals[.energyKcal] ?? 0, proteinG: totals[.proteinG] ?? 0,
                                             carbsG: totals[.carbsG] ?? 0, goals: goals).energy
                }
            } else {
                let span = kind == .week ? FoodQuality.weekSpan : FoodQuality.monthSpan
                note = FoodQuality.period(span: span, lastDay: today, entries: all, facts: facts, male: male, options: options,
                                          today: tomorrow)
                if let before = FoodQuality.shifted(today, by: -span, calendar: .current) {
                    previous = FoodQuality.period(span: span, lastDay: before, entries: all, facts: facts, male: male,
                                                  options: options, today: tomorrow)
                }
            }
            return CoreRead.json(RecapWire(FoodNotice.recap(kind: kind, note: note, previous: previous, goal: goal, badges: [])))
        default:
            break
        }

        let usual = FoodQuality.usualKcal(entries: all, before: day) ?? goals?.kcal
        let dayResult = FoodQuality.day(day, entries: all, facts: facts, male: male, options: options, usualKcal: usual, today: today)
        var dayNote: FoodQuality.Note?, nothing = false, logged: Double?, needed: Double?
        switch dayResult {
        case .success(let note): dayNote = note
        case .failure(let error):
            switch error.reason {
            case .nothing: nothing = true
            case .tooLittle(let l, let n): logged = l; needed = n
            }
        }
        let week = FoodQuality.period(span: FoodQuality.weekSpan, lastDay: day, entries: all, facts: facts, male: male,
                                      options: options, today: today)
        let month = FoodQuality.period(span: FoodQuality.monthSpan, lastDay: day, entries: all, facts: facts, male: male,
                                       options: options, today: today)
        let trend = (0..<8).reversed().compactMap { back -> FoodQuality.Note? in
            guard let last = FoodQuality.shifted(day, by: -7 * back, calendar: .current) else { return nil }
            return FoodQuality.period(span: FoodQuality.weekSpan, lastDay: last, entries: all, facts: facts, male: male,
                                      options: options, today: today)
        }
        var goalWire: GoalWire?
        let eaten = all.filter { $0.day == day }
        if let goals, !eaten.isEmpty {
            let totals = NutrientAmounts.sum(eaten.map { NutrientAmounts(stored: $0.totals) })
            let state = FoodGoalState.day(kcal: totals[.energyKcal] ?? 0, proteinG: totals[.proteinG] ?? 0,
                                          carbsG: totals[.carbsG] ?? 0, goals: goals)
            goalWire = GoalWire(energy: state.energy.rawValue, ratio: state.energyRatio, proteinMet: state.proteinMet,
                                carbsWithinCap: state.carbsWithinCap)
        }
        let badges = FoodBadges.summary(entries: all, facts: facts, male: male, options: options,
                                        usualFallbackKcal: goals?.kcal, today: today)
        return CoreRead.json(QualityWire(day: dayNote, missingLogged: logged, missingNeeded: needed, nothing: nothing,
                                         week: week, month: month, trend: trend, goal: goalWire,
                                         earned: badges.earned.map { EarnedWire(key: key($0.badge), day: $0.day) },
                                         streak: badges.streakDays))
    }

    struct QualityWire: Encodable {
        var day: FoodQuality.Note?
        var missingLogged: Double?, missingNeeded: Double?
        var nothing: Bool
        var week: FoodQuality.Note?, month: FoodQuality.Note?
        var trend: [FoodQuality.Note]
        var goal: GoalWire?
        var earned: [EarnedWire]
        var streak: Int
    }

    struct RecapWire: Encodable {
        var kind: String, score: Double?, previous: Double?, strongest: String?, weakest: String?, goal: String?
        init(_ recap: FoodNotice.Recap) {
            kind = recap.kind.rawValue; score = recap.note?.score; previous = recap.previous?.score
            strongest = recap.strongest?.rawValue; weakest = recap.weakest?.rawValue; goal = recap.goal?.rawValue
        }
    }
}
