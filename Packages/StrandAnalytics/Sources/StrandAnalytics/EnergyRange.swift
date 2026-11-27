import Foundation

/// Where a finished day's burn likely lies (owner decision 2026-11-27, open point 3 of the everyday plan): one
/// figure claims a precision no wearable has, so the Energy page names a range beside it, the same on both
/// platforms and for the coach. Today keeps its own forecast range (`DailyEnergySummary.projectedRangeKcal`).
///
/// Two errors make it up: what the strap model publishes about its own day (`uncertaintyFraction`), and the
/// basal formula's miss for a single body, about a tenth for most adults (Frankenfield 2005). Once the wearer
/// adjusted the strap to the scale, the scale has measured that miss, and the range narrows to the scale's own.
public enum EnergyRange {
    public static let formulaError = 0.10
    /// The scale's figure is offered only under 10 % of its own error (`ScaleBurn.maximumRelativeError`); in force
    /// over weeks, about half of that is left.
    public static let scaleError = 0.05
    public static let maximumError = 0.30

    public struct Likely: Equatable, Sendable {
        public var low: Double
        public var high: Double
        public var narrowedByScale: Bool
    }

    /// Nil without a total, or for today (its forecast range speaks for it).
    public static func likely(_ summary: DailyEnergySummary, isToday: Bool) -> Likely? {
        guard !isToday, let total = summary.totalBurnedSoFar, total.isFinite, total > 0 else { return nil }
        let scaled = summary.scaleCorrectionFactor != nil
        let model = summary.uncertaintyFraction.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? formulaError
        let relative = scaled ? scaleError : min(maximumError, (model * model + formulaError * formulaError).squareRoot())
        return Likely(low: total * (1 - relative), high: total * (1 + relative), narrowedByScale: scaled)
    }
}
