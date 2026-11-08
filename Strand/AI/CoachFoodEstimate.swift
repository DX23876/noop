import Foundation
import StrandCore
import WhoopStore

/// Choosing the BLS food a product's missing vitamins and minerals are borrowed from (decision 2026-11-08). The
/// coach's CHAT model picks among BLS candidates the phone found, or none; the numbers always come from the BLS
/// (`FoodEstimate.filled`). Only with the coach on and the wearer's switch on. Shared with Android (`Shared/`).
enum CoachFoodEstimate {
    static let system = """
        You match a packaged food to the most similar generic food in the German Nutrient Database (BLS), so its \
        missing vitamins and minerals can be borrowed. Judge by what the product is made of (main ingredients, \
        processing, cooked or raw), not by its brand. Reply with JSON only: {"pick": 2} with the index of the best \
        entry, or {"pick": -1} when none is close enough to borrow from.
        """

    static func prompt(_ item: FoodItem, candidates: [FoodItem]) -> String {
        var text = "Product: \(item.name)"
        if let brand = item.brand { text += " (\(brand))" }
        if let group = item.group { text += "\nCategory: \(group)" }
        let stated = FoodNutrient.macros.compactMap { n in item.per100g[n].map { "\(n.rawValue) \(Int($0.rounded()))" } }
        if !stated.isEmpty { text += "\nPer 100 g: " + stated.joined(separator: ", ") }
        text += "\nCandidates:\n"
        for (index, candidate) in candidates.enumerated() {
            let kcal = candidate.per100g[.energyKcal].map { " (\(Int($0.rounded())) kcal/100 g)" } ?? ""
            text += "\(index): \(candidate.name)\(kcal)\n"
        }
        return text
    }

    static func parsePick(_ reply: String, count: Int) -> Int? {
        guard let object = CoachFoodLogging.jsonObject(in: reply), let pick = (object["pick"] as? NSNumber)?.intValue,
              (0..<count).contains(pick) else { return nil }
        return pick
    }

    /// BLS candidates for a product: its name, then its name without the brand's words, then its first two words.
    static func candidates(for item: FoodItem, catalog: FoodCatalog) async -> [FoodItem] {
        var queries = [item.name]
        let words = item.name.split(separator: " ").map(String.init)
        if words.count > 2 { queries.append(words.prefix(2).joined(separator: " ")) }
        if let last = words.last, last.count > 3 { queries.append(last) }
        var out: [FoodItem] = []
        for query in queries {
            for found in await catalog.search(query, limit: 40) where found.source == .bls && !out.contains(where: { $0.id == found.id }) {
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
        let candidates = await CoachFoodEstimate.candidates(for: item, catalog: catalog)
        guard !candidates.isEmpty,
              let reply = await strongComplete(system: CoachFoodEstimate.system,
                                               user: CoachFoodEstimate.prompt(item, candidates: candidates)),
              let pick = CoachFoodEstimate.parsePick(reply, count: candidates.count) else { return nil }
        let filled = FoodEstimate.filled(item, from: candidates[pick])
        return filled.estimatedFrom == nil ? nil : filled
    }

    /// The cart's products with their gaps filled and kept as the wearer's own, so each product is matched once.
    /// Lines that need nothing, or find no match, come back unchanged.
    func fillingMissingNutrients(_ items: [FoodItem], store: WhoopStore) async -> [FoodItem] {
        var out: [FoodItem] = []
        for item in items {
            guard let filled = await estimateMissingNutrients(item),
                  let kept = await FoodLibrary.saveOwn(store: store, filled, origin: item.source == .own ? .own : .online)
            else { out.append(item); continue }
            out.append(kept)
        }
        return out
    }
}
