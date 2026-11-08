import Foundation

/// The evening's one sentence under the plate: at most two plain observations about the day, read against the same
/// goals the plate and the nutrient card show, so the sentence and the figures can never disagree. Rule-based; it
/// needs no coach.
public enum FoodDaySentence {
    public struct Point: Equatable, Sendable {
        public var nutrient: FoodNutrient
        /// True for "plenty" (good for a minimum, a warning for a maximum), false for "short".
        public var plenty: Bool
        /// Something to watch rather than something going well.
        public var watch: Bool
    }

    /// From this hour of the shown day on, the day is far enough along to say something about it.
    public static let fromHour = 18

    /// Protein against its gram goal, then fibre, then the limits (saturated fat, sugar, salt). The best thing
    /// first and the thing to watch second; nil when nothing stands out or the day carries too little to judge.
    public static func points(totals: NutrientAmounts, proteinGoalG: Double?,
                              references: [FoodNutrient: FoodReference.Value]) -> [Point] {
        guard (totals[.energyKcal] ?? 0) >= 600 else { return [] }
        var good: [Point] = [], watch: [Point] = []
        if let goal = proteinGoalG, goal > 0, let protein = totals[.proteinG] {
            if protein >= goal { good.append(Point(nutrient: .proteinG, plenty: true, watch: false)) }
            else if protein < goal * 0.6 { watch.append(Point(nutrient: .proteinG, plenty: false, watch: true)) }
        }
        if let fibre = totals[.fiberG], let ref = references[.fiberG], ref.kind == .atLeast, ref.amount > 0 {
            if fibre >= ref.amount { good.append(Point(nutrient: .fiberG, plenty: true, watch: false)) }
            else if fibre < ref.amount * 0.5 { watch.append(Point(nutrient: .fiberG, plenty: false, watch: true)) }
        }
        for nutrient in [FoodNutrient.satFatG, .sugarG, .saltG] {
            guard let value = totals[nutrient], let ref = references[nutrient], ref.kind == .atMost, ref.amount > 0 else { continue }
            if value > ref.amount { watch.append(Point(nutrient: nutrient, plenty: true, watch: true)) }
        }
        return Array((good.prefix(1) + watch.prefix(1)).prefix(2))
    }
}
