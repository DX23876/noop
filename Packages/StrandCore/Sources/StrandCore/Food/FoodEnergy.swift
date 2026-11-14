import Foundation

/// Energy worked out from the nutrients that carry it, with the conversion factors of EU regulation 1169/2011
/// (Annex XIV), the ones a label's kilocalorie figure is calculated from. Two jobs: filling in an energy value a
/// source leaves out, and saying when a stated value and the nutrients printed beside it cannot both be right.
/// One resolver for both, so a card, a field and a note cannot disagree about the same product.
///
/// A label states carbohydrate without fibre, so fibre carries its own factor here. Sugar alcohols have a factor
/// of their own (2.4) and no field in the log, so a sugar-free product can work out higher than its label without
/// either figure being wrong. That is why a difference is only shown for the wearer to judge, and never used to
/// overwrite a stated value.
public enum FoodEnergy {
    /// Kilocalories per gram, per nutrient.
    public static let factors: [(nutrient: FoodNutrient, kcalPerGram: Double)] =
        [(.proteinG, 4), (.carbsG, 4), (.fatG, 9), (.fiberG, 2), (.alcoholG, 7)]

    /// The three the arithmetic cannot do without: no other field can stand in for them.
    public static let required: [FoodNutrient] = [.proteinG, .carbsG, .fatG]

    /// Energy per 100 g from the nutrients, nil unless protein, carbohydrate and fat are all known.
    public static func fromNutrients(_ amounts: NutrientAmounts) -> Double? {
        guard required.allSatisfy({ amounts[$0] != nil }) else { return nil }
        return factors.reduce(0) { $0 + (amounts[$1.nutrient] ?? 0) * $1.kcalPerGram }
    }

    /// What each nutrient contributes to the computed value, in kilocalories per 100 g, in `factors` order and
    /// without the ones that contribute nothing. The arithmetic behind the split a screen draws.
    public static func contributions(_ amounts: NutrientAmounts) -> [(nutrient: FoodNutrient, kcal: Double)] {
        guard fromNutrients(amounts) != nil else { return [] }
        return factors.compactMap { factor in
            let kcal = (amounts[factor.nutrient] ?? 0) * factor.kcalPerGram
            return kcal > 0 ? (factor.nutrient, kcal) : nil
        }
    }

    /// How far a stated value may sit from the nutrients before the two are called a disagreement: a fifth of the
    /// computed value, and at least `minimumDifference`, so rounding on a thin product says nothing.
    public static let tolerance = 0.2
    /// Below this the two figures are too close in absolute terms to call, whatever the share says.
    public static let minimumDifference = 15.0

    /// A stated energy value beside the one its own nutrients give.
    public struct Check: Equatable, Sendable {
        public let stated: Double?
        public let computed: Double

        public init(stated: Double?, computed: Double) {
            self.stated = stated
            self.computed = computed
        }

        /// Nothing stated: the computed value is all there is.
        public var isMissing: Bool { stated == nil }

        /// Stated minus computed, in kilocalories per 100 g; positive when the source claims more.
        public var difference: Double? { stated.map { $0 - computed } }

        /// That difference as a share of the computed value.
        public var share: Double? {
            guard let difference, computed > 0 else { return nil }
            return difference / computed
        }

        /// The two figures cannot both be right.
        public var disagrees: Bool {
            guard let difference, let share else { return false }
            return abs(difference) >= minimumDifference && abs(share) > tolerance
        }
    }

    /// The stated and the computed energy of `amounts`, nil when the nutrients cannot give one.
    public static func check(_ amounts: NutrientAmounts) -> Check? {
        guard let computed = fromNutrients(amounts) else { return nil }
        return Check(stated: amounts[.energyKcal], computed: computed)
    }

    /// Marks an energy value worked out here, kept apart from a value borrowed from a similar food or guessed by
    /// the coach (`FoodEstimate`), so a screen can say which of the three it is showing.
    public static let markPrefix = "calc:"
    public static var mark: String { markPrefix + FoodNutrient.energyKcal.rawValue }

    /// Whether an item's or an entry's marks say its energy was worked out from its nutrients.
    public static func isComputed(_ keys: [String]?) -> Bool { keys?.contains(mark) ?? false }

    /// `amounts` with an energy value worked out from the nutrients when none is stated. A stated value is never
    /// touched: the label is the truth for it, even where it disagrees.
    public static func filling(_ amounts: NutrientAmounts) -> (amounts: NutrientAmounts, filled: Bool) {
        guard amounts[.energyKcal] == nil, let computed = fromNutrients(amounts) else { return (amounts, false) }
        var next = amounts
        next[.energyKcal] = computed
        return (next, true)
    }

    /// `item` with a missing energy value filled from its nutrients and marked as computed.
    public static func filled(_ item: FoodItem) -> FoodItem {
        let result = filling(item.per100g)
        guard result.filled else { return item }
        var next = item
        next.per100g = result.amounts
        next.estimatedKeys = ((next.estimatedKeys ?? []) + [mark]).sorted()
        return next
    }
}
