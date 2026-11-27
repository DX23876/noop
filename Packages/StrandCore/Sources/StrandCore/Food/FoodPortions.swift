import Foundation

/// A product's package as its label states it: one piece of `amount` g or ml, `count` pieces in the pack
/// (owner, 2026-11-25). "6 x 330 ml" is six cans of 330 ml, "400 g" one pack of 400 g.
public struct FoodPackage: Equatable, Sendable {
    public var amount: Double
    public var count: Int
    public var liquid: Bool

    public init(amount: Double, count: Int = 1, liquid: Bool) {
        self.amount = amount; self.count = max(1, count); self.liquid = liquid
    }

    /// The package from Open Food Facts' `quantity` text, falling back to `product_quantity` with its unit. Nil
    /// when neither gives a plausible size: a missing size is left missing, never guessed.
    public static func parse(quantity: String?, productQuantity: Double?, unit: String?) -> FoodPackage? {
        if let quantity, let parsed = parse(text: quantity) { return parsed }
        guard let productQuantity, let unit, let factor = unitFactor(unit.lowercased()) else { return nil }
        return plausible(FoodPackage(amount: productQuantity * factor.scale, liquid: factor.liquid))
    }

    /// "6 x 330 ml", "6×0,33 l", "500g", "1,5 l", "75 cl", "1 kg". Anything else, such as "2 Stück" or a size
    /// in ounces, is no package.
    static func parse(text: String) -> FoodPackage? {
        let cleaned = text.lowercased().replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "×", with: "x")
        let pattern = #"^\s*(?:(\d{1,3})\s*x\s*)?(\d+(?:\.\d+)?)\s*(kg|g|ml|cl|l)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) else { return nil }
        func group(_ i: Int) -> String? {
            Range(match.range(at: i), in: cleaned).map { String(cleaned[$0]) }
        }
        guard let value = group(2).flatMap(Double.init), let unit = group(3), let factor = unitFactor(unit) else { return nil }
        let count = group(1).flatMap(Int.init) ?? 1
        return plausible(FoodPackage(amount: value * factor.scale, count: count, liquid: factor.liquid))
    }

    static func unitFactor(_ unit: String) -> (scale: Double, liquid: Bool)? {
        switch unit {
        case "g": return (1, false)
        case "kg": return (1_000, false)
        case "ml": return (1, true)
        case "cl": return (10, true)
        case "l": return (1_000, true)
        default: return nil
        }
    }

    static func plausible(_ package: FoodPackage) -> FoodPackage? {
        (1...10_000).contains(package.amount) && package.count <= 48 ? package : nil
    }
}

/// The amounts the amount sheet offers for one food, in the order shown (owner, 2026-11-25). Worked out here so
/// both platforms offer the same ones; the screens only name them. Every option comes from what the product
/// states or what the wearer logged before: a size that is not stated is not offered.
public enum FoodPortions {
    public enum Kind: Equatable, Sendable {
        /// The product's serving, with its own label when it has one.
        case serving(label: String?)
        /// What the wearer logged last time.
        case lastTime
        /// One piece of a multipack ("1 of 6").
        case piece(count: Int)
        /// Half of a single pack.
        case halfPack
        /// The whole pack, a multipack's every piece included.
        case wholePack(count: Int)
        /// A round amount in the food's unit.
        case amount
    }

    public struct Option: Equatable, Sendable {
        public var kind: Kind
        /// Grams, or millilitres for a liquid (the nutrients of a drink are stated per 100 ml).
        public var amount: Double
    }

    public static func options(for item: FoodItem, lastAmount: Double?) -> [Option] {
        var out: [Option] = []
        func add(_ kind: Kind, _ amount: Double) {
            guard amount > 0, amount <= 10_000, !out.contains(where: { abs($0.amount - amount) < 0.01 }) else { return }
            out.append(Option(kind: kind, amount: amount))
        }
        if let serving = item.servingG { add(.serving(label: item.servingLabel), serving) }
        if let lastAmount { add(.lastTime, lastAmount) }
        if let amount = item.packageAmount, amount > 0 {
            let count = max(1, item.packageCount ?? 1)
            if count > 1 {
                add(.piece(count: count), amount)
                add(.wholePack(count: count), amount * Double(count))
            } else {
                add(.halfPack, amount / 2)
                add(.wholePack(count: 1), amount)
            }
        }
        for round in item.liquid == true ? [100.0, 250, 500] : [50.0, 100, 250] { add(.amount, round) }
        return out
    }
}
