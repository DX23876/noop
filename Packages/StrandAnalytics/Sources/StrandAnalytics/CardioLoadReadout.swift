import Foundation

/// What a cardio-load card can say about the week, decided once for every platform that draws it.
///
/// The figure behind cardio load is the wearer's own heart-rate load, and it means nothing on its own:
/// 109 of it is neither good nor bad and belongs to no everyday scale. A card can therefore say one of
/// four things, and which one is a rule, not a matter of taste — two apps showing different words for
/// the same week would be two readouts of one fact. The words themselves stay with each platform; the
/// choice is here.
public enum CardioLoadReadout: Equatable, Sendable {
    /// The week against the wearer's own usual week, which is the only thing the load supports.
    /// `readsLow` when so few of the week's sessions carry heart rate that the comparison understates it.
    case comparison(percent: Double, band: RelativeLoadBand?, readsLow: Bool)
    /// Nothing in the window was recorded with heart rate, so there is no load to compare.
    case noHeartRate
    /// Not enough of the wearer's own complete weeks for a personal usual.
    case notEnoughWeeks
    /// Weeks enough, but too few of these sessions carry heart rate for a comparison.
    case tooFewMeasured(measured: Int, possible: Int)

    /// A stable name for the boundary to another language, so the platform drawing the card switches on
    /// the decision rather than making it again.
    public var kind: String {
        switch self {
        case .comparison: return "comparison"
        case .noHeartRate: return "noHeartRate"
        case .notEnoughWeeks: return "notEnoughWeeks"
        case .tooFewMeasured: return "tooFewMeasured"
        }
    }

    /// - Parameters:
    ///   - possibleCount: sessions in the lane's window that could carry heart rate.
    ///   - measuredCount: how many of them do.
    ///   - seriesMeasured: whether the window holds any usable heart-rate trace at all.
    ///   - completeWeeks: the wearer's own complete weeks behind the comparison.
    /// Returns nil when the window holds no cardio at all, where a card has nothing to say rather than
    /// something cautious to say.
    public static func resolve(possibleCount: Int, measuredCount: Int, seriesMeasured: Bool,
                               percentChange: Double?, band: RelativeLoadBand?,
                               completeWeeks: Int,
                               baselineWeeks: Int = TrainingLoad.personalBaselineWeeks) -> CardioLoadReadout? {
        guard possibleCount > 0 else { return nil }
        guard seriesMeasured else { return .noHeartRate }
        if let percentChange {
            let thin = Double(measuredCount) / Double(possibleCount) < TrainingLoad.trustedRatedShare
            return .comparison(percent: percentChange, band: band, readsLow: thin)
        }
        if completeWeeks < baselineWeeks { return .notEnoughWeeks }
        return .tooFewMeasured(measured: measuredCount, possible: possibleCount)
    }
}
