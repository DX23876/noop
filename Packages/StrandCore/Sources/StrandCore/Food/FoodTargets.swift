import Foundation
import StrandAnalytics

/// The day's food goals, resolved once for every screen that shows them (Food on iOS and Android, Today's
/// energy card, the coach), so two readouts of the goal can never disagree.
public enum FoodTargets {
    /// Where the calorie goal comes from, said on the screen in words.
    public enum CalorieBasis: String, Sendable, Codable { case measured, formula }

    public struct Calories: Equatable, Sendable, Codable {
        /// What to eat today to follow the wearer's own plan.
        public var kcal: Double
        /// The usual burn the goal starts from.
        public var burnKcal: Double
        /// The plan's daily deficit (negative) or surplus (positive); zero when the wearer holds weight.
        public var planDeltaKcal: Double
        public var basis: CalorieBasis
    }

    /// The calorie goal: the measured usual burn of the last weeks (strap and Health), else the formula's,
    /// plus the plan's daily change. Nil without either burn figure. Never below the basal rate's floor of
    /// 1,200 kcal: the screen is not a place to suggest a crash diet.
    public static func calories(measuredMeanKcal: Double?, allDaysMeanKcal: Double?, formulaTdeeKcal: Double?,
                                dailyDeltaKcal: Double?) -> Calories? {
        let measured = measuredMeanKcal ?? allDaysMeanKcal
        guard let burn = measured ?? formulaTdeeKcal, burn.isFinite, burn > 0 else { return nil }
        let delta = dailyDeltaKcal.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return Calories(kcal: max(minimumKcal, burn + delta), burnKcal: burn, planDeltaKcal: delta,
                        basis: measured != nil ? .measured : .formula)
    }

    /// The lowest goal shown, whatever the plan says.
    public static let minimumKcal: Double = 1_200
}
