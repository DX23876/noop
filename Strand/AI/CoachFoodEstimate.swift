import Foundation
import StrandCore
import WhoopStore

/// Choosing the BLS food a product's missing vitamins and minerals are borrowed from (decision 2026-11-08). The
/// coach's CHAT model picks among BLS candidates the phone found, or none; the numbers always come from the BLS
/// (`FoodEstimate.filled`). Only with the coach on and the wearer's switch on. Shared with Android (`Shared/`).
enum CoachFoodEstimate {
    static let system = """
        You match a packaged food to the generic food in the German Nutrient Database (BLS) whose vitamins and \
        minerals it most likely shares, so its missing values can be borrowed. Judge by what it is made of: main \
        ingredients, processing, and the protein, carbohydrate, sugar and fat per 100 g. A high-protein, light, sugar-free \
        or fortified version is usually NOT like the ordinary product with the same name: a protein pudding made from \
        milk protein is closer to low-fat quark or skyr than to vanilla pudding. Products with no real counterpart \
        (protein bars, energy drinks, supplements, meal replacements) get -1. Reply with JSON only: {"pick": 2} with \
        the index of the best entry, or {"pick": -1} when none is close enough.
        """

    static func prompt(_ item: FoodItem, candidates: [FoodItem]) -> String {
        var text = "Product: \(item.name)"
        if let brand = item.brand { text += " (\(brand))" }
        if let group = item.group { text += "\nCategory: \(group)" }
        let stated = [("protein", FoodNutrient.proteinG), ("carbs", .carbsG), ("sugar", .sugarG), ("fat", .fatG)]
            .compactMap { label, n in item.per100g[n].map { "\(label) \(String(format: "%.1f", $0)) g" } }
        if !stated.isEmpty { text += "\nPer 100 g: " + stated.joined(separator: ", ") }
        text += "\nCandidates:\n"
        func macros(_ food: FoodItem) -> String {
            [("protein", FoodNutrient.proteinG), ("carbs", .carbsG), ("sugar", .sugarG), ("fat", .fatG)]
                .compactMap { label, n in food.per100g[n].map { "\(label) \(String(format: "%.1f", $0)) g" } }.joined(separator: ", ")
        }
        for (index, candidate) in candidates.enumerated() {
            text += "\(index): \(candidate.name) (\(macros(candidate)))\n"
        }
        return text
    }

    /// The free estimate's prompt, used only when no BLS food is close enough (decision 2026-11-08).
    static let estimateSystem = """
        You estimate vitamins and minerals per 100 g for a packaged food that does not state them, for a personal \
        nutrition diary. Use what you know about this kind of product and its typical ingredients. Rules: only the \
        nutrients asked for; never change or repeat the stated values; do not assume fortification unless the name or \
        stated values show it; give null when you cannot tell. Units are in the key (g, mg, ug). Reply with JSON only, \
        for example {"calcium_mg": 120, "vitamin_d_ug": null}.
        """

    static func estimatePrompt(_ item: FoodItem, missing: [FoodNutrient]) -> String {
        var text = "Product: \(item.name)"
        if let brand = item.brand { text += " (\(brand))" }
        if let group = item.group { text += "\nCategory: \(group)" }
        let stated = FoodNutrient.allCases.compactMap { n in item.per100g[n].map { "\(n.rawValue) \($0)" } }
        text += "\nStated per 100 g: " + stated.joined(separator: ", ")
        text += "\nEstimate: " + missing.map(\.rawValue).joined(separator: ", ")
        return text
    }

    static func parseEstimate(_ reply: String) -> [FoodNutrient: Double] {
        guard let object = CoachFoodLogging.jsonObject(in: reply) else { return [:] }
        var out: [FoodNutrient: Double] = [:]
        for (key, value) in object {
            if let nutrient = FoodNutrient(rawValue: key), let number = (value as? NSNumber)?.doubleValue { out[nutrient] = number }
        }
        return out
    }

    static func parsePick(_ reply: String, count: Int) -> Int? {
        guard let object = CoachFoodLogging.jsonObject(in: reply), let pick = (object["pick"] as? NSNumber)?.intValue,
              (0..<count).contains(pick) else { return nil }
        return pick
    }

    /// BLS candidates for a product: the foods closest in make-up first, then matches by name, all within the
    /// make-up limit, since a name match with an unlike profile cannot lend values anyway.
    static func candidates(for item: FoodItem, catalog: FoodCatalog) async -> [FoodItem] {
        var out = await catalog.nearestBLS(to: item, limit: 8).filter { FoodEstimate.closeEnough(item, $0) }
        var queries = [item.name]
        let words = item.name.split(separator: " ").map(String.init)
        if words.count > 2 { queries.append(words.prefix(2).joined(separator: " ")) }
        if let last = words.last, last.count > 3 { queries.append(last) }
        for query in queries {
            for found in await catalog.search(query, limit: 40)
                where found.source == .bls && FoodEstimate.closeEnough(item, found) && !out.contains(where: { $0.id == found.id }) {
                out.append(found)
            }
            if out.count >= 12 { break }
        }
        return Array(out.prefix(12))
    }
}

extension AICoachEngine {
    /// `item` with its missing nutrients borrowed from the BLS food the chat model picked, or nil when nothing fits
    /// or the coach could not answer.
    func estimateMissingNutrients(_ item: FoodItem, catalog: FoodCatalog = .shared) async -> FoodItem? {
        guard FoodEstimate.needsFilling(item) else { return nil }
        // First a measured neighbour from the BLS; only when none is close enough, the model's own estimate.
        let candidates = await CoachFoodEstimate.candidates(for: item, catalog: catalog)
        if !candidates.isEmpty,
           let reply = await strongComplete(system: CoachFoodEstimate.system,
                                            user: CoachFoodEstimate.prompt(item, candidates: candidates)),
           let pick = CoachFoodEstimate.parsePick(reply, count: candidates.count) {
            let filled = FoodEstimate.filled(item, from: candidates[pick])
            if filled.estimatedFrom != nil { return filled }
        }
        let missing = FoodEstimate.missing(item)
        guard let reply = await strongComplete(system: CoachFoodEstimate.estimateSystem,
                                               user: CoachFoodEstimate.estimatePrompt(item, missing: missing)) else { return nil }
        var ceilings: [FoodNutrient: Double] = [:]
        for nutrient in missing { ceilings[nutrient] = await catalog.blsMaximum(nutrient) }
        let estimated = FoodEstimate.filledByModel(item, values: CoachFoodEstimate.parseEstimate(reply)) { ceilings[$0] }
        return estimated.estimatedFrom == nil ? nil : estimated
    }

    /// The cart's products with their gaps filled and kept as the wearer's own, so each product is matched once.
    /// Lines that need nothing, or find no match, come back unchanged.
    func fillingMissingNutrients(_ items: [FoodItem], store: WhoopStore) async -> [FoodItem] {
        var out: [FoodItem] = []
        for item in items {
            guard let filled = await estimateMissingNutrients(item),
                  let kept = await FoodLibrary.saveOwn(store: store, filled, origin: item.source == .online ? .online : .own)
            else { out.append(item); continue }
            out.append(kept)
        }
        return out
    }
}
