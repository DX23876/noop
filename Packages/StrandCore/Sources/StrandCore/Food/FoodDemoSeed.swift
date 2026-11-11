import Foundation
import WhoopStore

/// A week of meals for the demo stores (`--demo-seed` on Apple, the demo flavour on Android), so the Food page,
/// its nutrient report and the energy balance show what a logged week looks like. Every food is a BLS food by
/// its code; a protein pudding shows a product whose missing nutrients were taken from a similar BLS food. Seeds
/// only into a food log that is still empty. Names are English by default, as the demo is shown to people who
/// read English; `english: false` keeps the BLS's German names.
public enum FoodDemoSeed {
    /// A BLS food by its code (`bls:…`), fixed so a search ranking can never swap milk for milk powder.
    struct Dish { let query: String; let grams: Double }
    struct Meal { let hour: Int; let minute: Int; let dishes: [Dish] }

    static let breakfasts: [[Dish]] = [
        [.init(query: "bls:C133000", grams: 80), .init(query: "bls:M111300", grams: 250), .init(query: "bls:F304100", grams: 100)],
        [.init(query: "bls:B101000", grams: 120), .init(query: "bls:Q611000", grams: 10), .init(query: "bls:E111132", grams: 120),
         .init(query: "bls:G561100", grams: 100)],
        [.init(query: "bls:M710100", grams: 250), .init(query: "bls:F503100", grams: 120), .init(query: "bls:H120100", grams: 20)],
    ]
    static let lunches: [[Dish]] = [
        [.init(query: "bls:V413182", grams: 200), .init(query: "bls:C352032", grams: 250), .init(query: "bls:G312152", grams: 200)],
        [.init(query: "bls:X5A8030", grams: 250), .init(query: "bls:B101000", grams: 60), .init(query: "bls:G543100", grams: 120)],
        [.init(query: "bls:E500032", grams: 250), .init(query: "bls:U010182", grams: 150), .init(query: "bls:G561100", grams: 150)],
    ]
    static let dinners: [[Dish]] = [
        [.init(query: "bls:T410062", grams: 180), .init(query: "bls:K110132", grams: 300), .init(query: "bls:G210132", grams: 150)],
        [.init(query: "bls:H861082", grams: 200), .init(query: "bls:C352032", grams: 200), .init(query: "bls:G620100", grams: 150)],
        [.init(query: "bls:M713100", grams: 250), .init(query: "bls:K110132", grams: 350), .init(query: "bls:Q160000", grams: 10)],
    ]
    static let snacks: [[Dish]] = [
        [.init(query: "bls:F110100", grams: 180), .init(query: "bls:H210100", grams: 30)],
        [.init(query: "bls:F503100", grams: 120)],
    ]

    /// The branded product with borrowed nutrients, as a wearer would have scanned it.
    static func proteinPudding(english: Bool) -> FoodItem { FoodItem(
        id: "off:4000000099999", source: .online, name: english ? "High Protein Pudding Vanilla" : "High Protein Pudding Vanille",
        brand: "Demo", group: "dairy-desserts", servingG: 200, servingLabel: english ? "1 cup (200 g)" : "1 Becher (200 g)",
        per100g: NutrientAmounts([.energyKcal: 76, .proteinG: 10, .carbsG: 5.6, .sugarG: 4.5, .fatG: 1.5, .saltG: 0.2]),
        barcode: "4000000099999") }

    @discardableResult
    public static func seedIfEmpty(store: WhoopStore, catalog: FoodCatalog = .shared, days: Int = 7, english: Bool = true,
                                   now: Date = Date(), calendar: Calendar = .current) async -> Int {
        let today = StoreReader.localDayKey(now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)),
              ((try? await store.foodLogEntries(from: StoreReader.localDayKey(start), to: today)) ?? []).isEmpty,
              (try? await catalog.prepareBundled()) != nil else { return 0 }

        var found: [String: FoodItem] = [:]
        func item(_ query: String) async -> FoodItem? {
            if let cached = found[query] { return cached }
            var hit = await catalog.item(id: query)
            if english, let name = hit?.nameEn, !name.isEmpty { hit?.name = name }
            found[query] = hit
            return hit
        }

        // The pudding's missing vitamins and minerals from low-fat quark, as the estimate would take them.
        var pudding: FoodItem?
        if let quark = await item("bls:M713100") {
            pudding = await FoodLibrary.saveOwn(store: store, FoodEstimate.filled(proteinPudding(english: english), from: quark), origin: .online)
        }

        var entries: [FoodLogEntry] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let isToday = offset == days - 1
            var meals = [Meal(hour: 7, minute: 30, dishes: breakfasts[offset % breakfasts.count]),
                         Meal(hour: 12, minute: 45, dishes: lunches[offset % lunches.count])]
            if !isToday {
                meals.append(Meal(hour: 16, minute: 0, dishes: snacks[offset % snacks.count]))
                meals.append(Meal(hour: 19, minute: 15, dishes: dinners[offset % dinners.count]))
            }
            for meal in meals {
                guard let at = calendar.date(bySettingHour: meal.hour, minute: meal.minute, second: 0, of: day) else { continue }
                for dish in meal.dishes {
                    guard let food = await item(dish.query) else { continue }
                    entries.append(FoodLog.entry(for: food, grams: dish.grams, at: at, origin: .search, now: at))
                }
            }
            if offset % 2 == 1, let pudding, let at = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: day), !isToday {
                entries.append(FoodLog.entry(for: pudding, grams: 200, at: at, origin: .barcode,
                                             portionLabel: pudding.servingLabel, now: at))
            }
        }
        guard !entries.isEmpty, await FoodLog.save(store: store, entries) else { return 0 }

        // Most past days marked as completely logged, so the real burn has days to work from; every sixth is
        // left unmarked, as a wearer forgets now and then.
        for offset in 0..<(days - 1) where offset % 6 != 5 {
            if let day = calendar.date(byAdding: .day, value: offset, to: start) {
                try? await store.setFoodDayComplete(StoreReader.localDayKey(day), true, at: Int(now.timeIntervalSince1970))
            }
        }

        // A recipe and two favourites, so "My foods" and "Favourites" are not empty.
        if let recipe = FoodLog.recipe(name: english ? "Porridge with berries" : "Porridge mit Beeren", from: entries.filter { $0.day == StoreReader.localDayKey(start) && $0.loggedAt == entries[0].loggedAt },
                                       servings: 1) {
            _ = try? await store.saveFoodRecipe(recipe)
        }
        for query in ["bls:C133000", "bls:M710100"] {
            if let food = found[query] {
                try? await store.setFoodFavourite(.init(foodId: food.id, name: food.name, addedAt: Int(now.timeIntervalSince1970)), on: true)
            }
        }
        return entries.count
    }
}
