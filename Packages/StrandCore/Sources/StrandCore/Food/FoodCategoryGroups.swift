import Foundation

/// What an Open Food Facts product is, read from its category IDs (owner, 2026-11-25). The IDs are the same in
/// every language ("en:rolled-oats" for Haferflocken, oats, flocons d'avoine), and a product's `categories_tags`
/// already carries every ancestor of its own category, so a rule names the broad category and finds every
/// product beneath it. Names were the only signal before, and only "vollkorn" and four English words made a
/// food whole grain: oats in any language did not count.
///
/// The result is written into `FoodItem.group` as comma-separated tokens that `FoodScore.kind` and its whole
/// grain check read. A food may carry several (a granola is whole grain and nuts). The rules were checked
/// against the category taxonomy of 2026-11-25 (14,968 categories).
public enum FoodCategoryGroups {
    public static let wholeGrain = "whole-grain"

    /// The group tokens for `tags`, or nil when none applies (the caller then keeps what it had).
    public static func group(for tags: [String]) -> String? {
        let tags = Set(tags.map { $0.lowercased() })
        guard !tags.isEmpty else { return nil }
        var out: [String] = []
        let beverage = tags.contains("en:beverages")
        if beverage {
            out.append(tags.contains("en:fruit-juices") || tags.contains("en:fruit-nectars") ? "fruit-juices-beverage" : "beverages")
        }
        if isWholeGrain(tags, beverage: beverage) { out.append(wholeGrain) }
        if !beverage {
            if tags.contains("en:legumes") || tags.contains("en:pulses") { out.append("legumes") }
            // Seeds count with nuts, as the score's nut words already do. Cereal grains and pulses sit under
            // "en:seeds" in the taxonomy too, and are neither.
            if tags.contains("en:nuts") || (tags.contains("en:seeds") && !tags.contains("en:cereals-and-their-products")
                                            && !tags.contains("en:legumes")) {
                out.append("nuts")
            }
            if tags.contains("en:prepared-meats") || tags.contains("en:sausages") || tags.contains("en:hams") {
                out.append("processed-meat")
            } else if tags.contains("en:meats") && !tags.contains("en:poultries") {
                out.append("meat")
            }
            if tags.contains("en:vegetables") || tags.contains("en:vegetables-based-foods") { out.append("vegetables") }
            if tags.contains("en:fruits") && !tags.contains("en:dried-fruits") { out.append("fruits") }
        }
        return out.isEmpty ? nil : out.joined(separator: ",")
    }

    /// Whole grain: every oat product that is eaten as the grain (flakes, groats, porridge, oat bread), and
    /// every cereal product whose own category says whole or wholemeal. "Whole or semi-whole" pasta is left
    /// out: half of it may be refined. Oat drinks and oat biscuits are not the grain.
    static func isWholeGrain(_ tags: Set<String>, beverage: Bool) -> Bool {
        guard !beverage else { return false }
        if tags.contains("en:brown-rices") { return true }
        if tags.contains("en:oats-and-their-products"),
           !tags.contains("en:dairy-substitutes"), !tags.contains("en:biscuits-and-cakes"),
           !tags.contains("en:sweet-snacks") {
            return true
        }
        let cereal = tags.contains("en:cereals-and-their-products") || tags.contains("en:pastas")
        return cereal && tags.contains { tag in
            !tag.contains("semi-whole")
                && ["en:whole-", "en:wholemeal", "en:wholegrain", "en:wholewheat"].contains(where: tag.hasPrefix)
        }
    }
}
