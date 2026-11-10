import Foundation

/// The real burn from food and weight (owner, 2026-11-10): what the wearer ate on completely logged days, less the
/// energy the weight trend stored or released, over the last four weeks. Beside it, what the strap measured on the
/// same days, so the wearer can see whether the strap runs high or low.
///
/// Only days the wearer marked as completely logged count. Guessing completeness from the amount eaten would drop
/// exactly the days on which they really ate little, and the estimate would lean high; a day with forgotten snacks
/// would make the burn look too low. Without enough marked days there is no figure, only what is still missing.
public enum DietExpenditure {
    public static let windowDays = 28
    public static let minCompleteDays = 14
    public static let minWeighIns = 6
    public static let minWeighSpanDays = 10

    public struct Estimate: Equatable, Sendable {
        /// The real burn, kcal a day.
        public var burnKcal: Double
        /// One standard error either side, from how far the weigh-ins scatter around the trend.
        public var rangeKcal: ClosedRange<Double>
        /// The strap's mean over the same completely logged days, when it measured them.
        public var strapKcal: Double?
        /// Real burn divided by the strap's; nil without a strap figure.
        public var realToStrap: Double? { strapKcal.flatMap { $0 > 0 ? burnKcal / $0 : nil } }
        public var completeDays: Int
        public var trendKgPerWeek: Double
    }

    public enum Outcome: Equatable, Sendable {
        case estimate(Estimate)
        /// Not enough yet: how many completely logged days and weigh-ins there are, and how many are needed.
        case missing(completeDays: Int, weighIns: Int)
    }

    /// `intakeByDay` is kcal per day from the food log, `completeDays` the days marked as completely logged,
    /// `weighIns` (day, kg), `strapByDay` the measured burn per day. Days after `today` are ignored.
    public static func estimate(intakeByDay: [String: Double], completeDays: Set<String>,
                                weighIns: [(day: String, kg: Double)], strapByDay: [String: Double], today: String,
                                kcalPerKg: Double = DietTargets.defaultKcalPerKg) -> Outcome {
        guard let end = WeightSeries.date(forDay: today),
              let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -(windowDays - 1), to: end) else {
            return .missing(completeDays: 0, weighIns: 0)
        }
        func inWindow(_ day: String) -> Bool {
            guard let date = WeightSeries.date(forDay: day) else { return false }
            return date >= start && date <= end
        }
        let days = completeDays.filter { inWindow($0) && (intakeByDay[$0] ?? 0) > 0 }.sorted()
        let weights = weighIns.filter { inWindow($0.day) && $0.kg.isFinite && $0.kg > 0 }
        let dates = weights.compactMap { WeightSeries.date(forDay: $0.day) }
        let span = dates.isEmpty ? 0 : (dates.max()!.timeIntervalSince(dates.min()!) / 86_400)
        guard days.count >= minCompleteDays, weights.count >= minWeighIns, span >= Double(minWeighSpanDays),
              let fit = trend(weights) else {
            return .missing(completeDays: days.count, weighIns: weights.count)
        }
        let intake = days.compactMap { intakeByDay[$0] }.reduce(0, +) / Double(days.count)
        let stored = fit.slopePerDay * kcalPerKg
        let burn = intake - stored
        let error = fit.slopeErrorPerDay * kcalPerKg
        let strapDays = days.compactMap { strapByDay[$0] }.filter { $0.isFinite && $0 > 0 }
        let strap = strapDays.isEmpty ? nil : strapDays.reduce(0, +) / Double(strapDays.count)
        return .estimate(Estimate(burnKcal: burn, rangeKcal: (burn - error)...(burn + error), strapKcal: strap,
                                  completeDays: days.count, trendKgPerWeek: fit.slopePerDay * 7))
    }

    /// Least-squares trend of the weigh-ins in kilograms a day, with the slope's standard error.
    static func trend(_ points: [(day: String, kg: Double)]) -> (slopePerDay: Double, slopeErrorPerDay: Double)? {
        // Whole days: a clock change must not stretch one day by an hour and bend the slope.
        let xy = points.compactMap { p in WeightSeries.date(forDay: p.day).map { (($0.timeIntervalSince1970 / 86_400).rounded(), p.kg) } }
        guard xy.count >= 3 else { return nil }
        let n = Double(xy.count)
        let mx = xy.map(\.0).reduce(0, +) / n, my = xy.map(\.1).reduce(0, +) / n
        let sxx = xy.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
        guard sxx > 0 else { return nil }
        let slope = xy.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        let residuals = xy.reduce(0) { sum, p in
            let r = p.1 - (my + slope * (p.0 - mx))
            return sum + r * r
        }
        return (slope, (residuals / (n - 2) / sxx).squareRoot())
    }
}
