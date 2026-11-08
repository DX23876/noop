import Foundation
import WhoopStore

/// The picture a meal card shows when the meal has no photo of its own: one of fourteen still lifes, chosen by the
/// food group that brought the most calories. Groups come from the source: the BLS code's letter, the Open Food
/// Facts PNNS group, or what an own food was saved with.
public enum FoodGroupMotif: String, CaseIterable, Sendable, Codable {
    case bread, grains, fruit, vegetables, legumes, dairy, eggs, fish, meat, poultry, sweets, drinks, fats, dishes

    /// The motif for a stored group code; nil for a group with no fitting picture (spices, salt) or none at all.
    public static func forGroup(_ group: String?) -> FoodGroupMotif? {
        guard let raw = group?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        if raw.count == 1 { return bls[raw] }
        return off.first { raw.contains($0.key) }?.motif
    }

    /// The motif a food id gives away by itself: a BLS code carries its group letter, a recipe is a dish.
    /// Other sources need the group looked up.
    public static func forFoodId(_ id: String?) -> FoodGroupMotif? {
        guard let id else { return nil }
        if id.hasPrefix("recipe:") { return .dishes }
        guard id.hasPrefix("bls:"), let letter = id.dropFirst("bls:".count).first else { return nil }
        return bls[String(letter).lowercased()]
    }

    /// The motif of the group that brought the most calories to these entries; nil when none has one.
    /// `groups` maps a food id to its stored group for foods whose id does not say it.
    public static func forMeal(_ entries: [FoodLogEntry], groups: [String: String] = [:]) -> FoodGroupMotif? {
        var kcal: [FoodGroupMotif: Double] = [:]
        for entry in entries {
            guard let motif = forFoodId(entry.foodId) ?? forGroup(entry.foodId.flatMap { groups[$0] }) else { continue }
            kcal[motif, default: 0] += entry.totals["energy_kcal"] ?? 0
        }
        // Ties fall to the order of `allCases`, so the same meal always shows the same picture.
        return allCases.filter { kcal[$0] != nil }.max { (kcal[$0] ?? 0) < (kcal[$1] ?? 0) }
    }

    /// BLS 4.0 main groups by the code's first letter.
    static let bls: [String: FoodGroupMotif] = [
        "b": .bread, "c": .grains, "d": .bread, "e": .eggs, "f": .fruit, "g": .vegetables, "h": .legumes,
        "k": .vegetables, "m": .dairy, "n": .drinks, "p": .drinks, "q": .fats, "s": .sweets, "t": .fish,
        "u": .meat, "v": .poultry, "w": .meat, "x": .dishes, "y": .dishes,
    ]

    /// Open Food Facts PNNS groups (level 2, lower case, hyphenated), matched by the first key the group contains.
    /// Order matters: "fruit-juices" is a drink before it is a fruit, "dairy-desserts" a sweet before dairy.
    static let off: [(key: String, motif: FoodGroupMotif)] = [
        ("juice", .drinks), ("nectar", .drinks), ("beverage", .drinks), ("water", .drinks), ("tea", .drinks),
        ("coffee", .drinks), ("dessert", .sweets), ("ice-cream", .sweets), ("sweet", .sweets), ("chocolate", .sweets),
        ("biscuit", .sweets), ("cake", .sweets), ("pastr", .sweets), ("fruit", .fruit), ("vegetable", .vegetables),
        ("soup", .dishes), ("potato", .vegetables), ("legume", .legumes), ("nut", .legumes), ("milk", .dairy),
        ("yogurt", .dairy), ("cheese", .dairy), ("egg", .eggs), ("fish", .fish), ("seafood", .fish),
        ("poultry", .poultry), ("meat", .meat), ("offal", .meat), ("bread", .bread), ("cereal", .grains),
        ("fat", .fats), ("dressing", .fats), ("meal", .dishes), ("pizza", .dishes), ("sandwich", .dishes),
        ("appetizer", .dishes),
    ]
}
