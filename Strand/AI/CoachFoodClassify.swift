import Foundation
import StrandCore
import WhoopStore

/// Working out what a food is made of, so the nutrition score can count it (owner, 2026-11-22). Open Food Facts
/// gives one coarse category and leaves many products without one at all, and a name only says "Vollkorn" when the
/// maker chose to write it, so oats, chia and a seed granola were counted as nothing at all.
///
/// The coach's CHAT model reads the name, the brand, the category tags, the ingredient list and the stated
/// nutrients, and answers with shares. The figures it may set are shares only: the grams always come from the
/// entry the wearer logged. Runs once per product, when the food is kept, and never again on its own
/// (`FoodClassification.currentVersion`). Shared with Android, which drives the same engine through
/// `coach.foodEnrich`.
enum CoachFoodClassify {
    static let system = """
        You work out what a packaged food is made of, so a nutrition score can count it. Reply with JSON only, \
        shares between 0 and 1, never grams: \
        {"groups": {"vegetables": 0.3, "nuts": 0.2}, "whole_grain": 0.4, "free_sugar": 0.8, "processing": 3}
        Rules:
        - "groups" holds at most three of: vegetables (also mushrooms, not potatoes or corn), fruit (whole fruit, \
        not juice and not dried), nuts (nuts, seeds, nut butter), legumes (beans, lentils, peas, soy), red_meat \
        (beef, pork, lamb, game; never poultry or fish), processed_meat (sausage, ham, bacon, cured or smoked \
        meat of any animal), drink (anything drunk). Each share is that share of the product's WEIGHT. A food that \
        is none of these, for example cheese, egg, oil, bread, fish, poultry or a sweet, gets an empty object: \
        that is an answer, not a failure.
        - "whole_grain" is the share of the product's weight that is whole-grain cereal. Oats, whole rye, whole \
        spelt and brown rice are whole grain whatever the name says; white flour is not. A protein bread is mostly \
        seeds and gluten, so its whole-grain share is small.
        - "free_sugar" is the share of the product's STATED sugar that is free sugar as the WHO means it: added \
        sugar, honey, syrup, concentrate and juice sugar. The sugar inside milk, plain yoghurt and whole fruit is \
        not free sugar, so plain milk is 0 and a sweetened yoghurt is between 0 and 1. Judge it from the \
        ingredient list when there is one.
        - "processing" is the NOVA group, 1 to 4, judged from the ingredient list by NOVA's own definitions. \
        1: unprocessed or minimally processed (oats, plain milk, eggs, plain meat or fish, frozen vegetables, \
        seeds, plain yoghurt). 2: a culinary ingredient (oil, butter, sugar, salt, flour). 3: processed, a food \
        made from group 1 and 2 ingredients by ordinary means (cheese, bread of flour, water, salt and yeast, \
        canned vegetables, simple cured meat, a granola of oats, nuts, honey and oil). 4: ultra-processed, an \
        industrial formulation whose character comes from substances not used in a home kitchen (protein \
        isolates, modified starch, hydrogenated fat, flavourings, emulsifiers, sweeteners, colours), such as \
        soft drinks, packaged snacks, instant noodles or reconstituted meat. One preservative, an acid, a \
        vitamin or a starter culture does not make a food ultra-processed: ask what the product mostly is. The \
        class the label database gives is worked out by rule from single markers and is often too strict; \
        decide for yourself.
        - Judge by what the food is made of, never by whether it is healthy. Leave a figure out when the product \
        does not let you tell.
        """

    static func prompt(_ item: FoodItem) -> String {
        var text = "Product: \(item.name)"
        if let brand = item.brand { text += " (\(brand))" }
        if let group = item.group { text += "\nCategory: \(group)" }
        if let categories = item.categories { text += "\nCategory tags: \(categories)" }
        if let nova = item.nova { text += "\nProcessing class (NOVA) from the label database, by rule: \(nova)" }
        if let ingredients = item.ingredients?.trimmingCharacters(in: .whitespacesAndNewlines), !ingredients.isEmpty {
            text += "\nIngredients: \(ingredients.prefix(600))"
        }
        let stated = [("energy", FoodNutrient.energyKcal), ("protein", .proteinG), ("carbs", .carbsG),
                      ("sugar", .sugarG), ("fat", .fatG), ("saturated fat", .satFatG), ("fibre", .fiberG)]
            .compactMap { label, n in item.per100g[n].map { "\(label) \(String(format: "%.1f", $0))" } }
        if !stated.isEmpty { text += "\nPer 100 g: " + stated.joined(separator: ", ") }
        return text
    }

    /// The model's answer as a classification, or nil when it answered nothing usable. An answer that claims more
    /// than a whole food, or a group the score does not know, is dropped rather than trimmed into shape.
    static func parse(_ reply: String) -> FoodClassification? {
        guard let object = CoachFoodLogging.jsonObject(in: reply) else { return nil }
        var shares: [FoodScore.Group: Double] = [:]
        for (key, value) in (object["groups"] as? [String: Any]) ?? [:] {
            guard let group = FoodScore.Group(rawValue: camel(key)), let number = (value as? NSNumber)?.doubleValue,
                  number > 0 else { continue }
            shares[group] = number
        }
        // A figure the model left out stays open (nil), so the name, category and drink rules still answer for it.
        let whole = (object["whole_grain"] as? NSNumber)?.doubleValue
        let free = (object["free_sugar"] as? NSNumber)?.doubleValue
        // Shares a little over the whole (0.6 nuts and 0.45 legumes) are scaled back to it rather than costing the
        // whole answer; a share alone above the whole is still refused below.
        let sum = shares.values.reduce(0, +)
        if sum > 1, sum <= 1.5, shares.values.allSatisfy({ $0 <= 1 }) {
            shares = shares.mapValues { $0 / sum }
        }
        // A processing class outside NOVA's four is left out, so the label's class stands, rather than refusing the
        // whole answer over it.
        let processing = (object["processing"] as? NSNumber).map(\.intValue).flatMap { (1...4).contains($0) ? $0 : nil }
        let out = FoodClassification(shares: shares, wholeGrainShare: whole, freeSugarShare: free,
                                     processing: processing, author: .coach)
        // An empty answer is a real answer ("this is a cheese"), so only an unsound one is refused.
        return out.isSound ? out : nil
    }

    /// `red_meat` as the prompt writes it, `redMeat` as the score names it.
    static func camel(_ key: String) -> String {
        let parts = key.split(separator: "_").map(String.init)
        guard let first = parts.first else { return key }
        return ([first] + parts.dropFirst().map(\.capitalized)).joined()
    }
}

/// Which products are being classified right now and which could not be in this run of the app, so one product
/// is never asked about twice at once (the Food page's pass and a log of the same product) and a product whose
/// answer failed is not asked about again on every visit, holding back the ones after it. A failure is retried on
/// the next start of the app.
final class FoodClassifyGate: @unchecked Sendable {
    static let shared = FoodClassifyGate()
    private let lock = NSLock()
    private var running: Set<String> = []
    private var failed: Set<String> = []

    /// Claims `id` for one classification; false when it is already running or failed in this run.
    func begin(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running.contains(id), !failed.contains(id) else { return false }
        running.insert(id)
        return true
    }

    func end(_ id: String, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        running.remove(id)
        if !succeeded { failed.insert(id) }
    }

    func isAvailable(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !running.contains(id) && !failed.contains(id)
    }
}

extension AICoachEngine {
    /// `item` with the coach's classification on it, or nil when the coach could not answer or the product is
    /// already being classified. The wearer's own classification is never asked about again: it stands
    /// (`FoodLibrary.keptClassification`).
    func classifying(_ item: FoodItem) async -> FoodItem? {
        guard item.classification?.author != .wearer, FoodClassifyGate.shared.begin(item.id) else { return nil }
        var out: FoodItem?
        defer { FoodClassifyGate.shared.end(item.id, succeeded: out != nil) }
        guard let reply = await strongComplete(system: CoachFoodClassify.system,
                                               user: CoachFoodClassify.prompt(item)),
              let classification = CoachFoodClassify.parse(reply) else { return nil }
        var next = item
        next.classification = classification
        out = next
        return next
    }
}

extension AICoachEngine {
    /// How many of the wearer's own foods one pass classifies, so a long history is worked through over a few
    /// visits instead of one burst of model calls.
    static let keptFoodsPerPass = 10

    /// The wearer's own foods kept before the coach classified products, or while it was off, classified once so
    /// their weight counts in the score (owner, 2026-11-28: many foods were counted as nothing). Never a food that
    /// already has a classification, the wearer's own above all, never a BLS row or a recipe, which say what they
    /// are through their ids. Returns how many were classified. Both platforms call it: iOS from the Food page,
    /// Android through `coach.foodClassifyKept`.
    func classifyingKeptFoods(store: WhoopStore) async -> Int {
        guard isConfigured else { return 0 }
        let today = StoreReader.localDayKey(Date())
        let entries = (try? await store.foodLogEntries(from: "2000-01-01", to: today)) ?? []
        var pending: [FoodItem] = []
        for id in Set(entries.compactMap(\.foodId)).sorted() where id.hasPrefix("own:") {
            // Skipped: a product being classified now or that failed in this run (`FoodClassifyGate`), so the
            // next ones are reached, and the wearer's correction of a catalogue row, whose code and name the
            // catalogue rules already read without a model.
            guard FoodClassifyGate.shared.isAvailable(id),
                  let item = await FoodLibrary.item(store: store, id: id), item.classification == nil,
                  item.source != .recipe else { continue }
            if let kept = try? await store.customFood(id: id), kept.sourceId?.hasPrefix("bls:") == true { continue }
            pending.append(item)
            if pending.count == Self.keptFoodsPerPass { break }
        }
        guard !pending.isEmpty else { return 0 }
        return await enriching(pending, store: store, fillGaps: false).filter { $0.classification != nil }.count
    }
}

extension AICoachEngine {
    /// Just logged products classified after their entries were saved, so logging never waits for the model
    /// (design review 2026-11-28). `kept` are the products as stored, `originals` as they were found: the stored
    /// copy does not keep the ingredient list or the category tags, which the coach reads, so they come from the
    /// original. Returns how many were classified.
    func classifyingLogged(_ kept: [FoodItem], originals: [FoodItem], store: WhoopStore) async -> Int {
        let merged = zip(kept, originals).map { stored, found -> FoodItem in
            var item = stored
            item.ingredients = item.ingredients ?? found.ingredients
            item.categories = item.categories ?? found.categories
            return item
        }
        let before = Set(merged.filter { $0.classification != nil }.map(\.id))
        return await enriching(merged, store: store, fillGaps: false)
            .filter { $0.classification != nil && !before.contains($0.id) }.count
    }
}
