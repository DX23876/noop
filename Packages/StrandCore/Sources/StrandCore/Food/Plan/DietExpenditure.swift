import Foundation
import StrandAnalytics

/// The real burn from food and weight on the Food page (owner, 2026-11-10), since 2026-11-27 the one scale estimate
/// (`ScaleBurn`, Q20 and Q21): eight weeks of days the wearer marked as completely logged and weigh-ins without a
/// water mark, a robust trend, and a figure only once it is certain to 10 %. Beside it, what the strap measured on
/// the same days, so the wearer can see whether the strap runs high or low.
///
/// Only days the wearer marked as completely logged count. Guessing completeness from the amount eaten would drop
/// exactly the days on which they really ate little, and the estimate would lean high; a day with forgotten snacks
/// would make the burn look too low. Without enough marked days there is no figure, only what is still missing.
public enum DietExpenditure {
    public static let windowDays = ScaleBurn.windowDays
    public static let minCompleteDays = ScaleBurn.minimumCompleteDays
    public static let minWeighIns = ScaleBurn.minimumWeighIns
    public static let minWeighSpanDays = ScaleBurn.minimumSpanDays

    public struct Estimate: Equatable, Sendable {
        /// The real burn, kcal a day.
        public var burnKcal: Double
        /// One standard error either side.
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

    /// `intakeByDay` is the kcal the energy plan counts per day (a typed day value wins over the food log, as
    /// everywhere), `completeDays` the days marked as completely logged, `weighIns` (day, kg) without a water mark,
    /// `strapByDay` the measured burn per day. Today and later days are left out.
    public static func estimate(intakeByDay: [String: Double], completeDays: Set<String>,
                                weighIns: [(day: String, kg: Double)], strapByDay: [String: Double], today: String,
                                kcalPerKg: Double = DietTargets.defaultKcalPerKg) -> Outcome {
        let complete = intakeByDay.filter { completeDays.contains($0.key) }
        switch ScaleBurn.estimate(completeIntake: complete, weighIns: weighIns, strapByDay: strapByDay, today: today,
                                  kcalPerKg: kcalPerKg) {
        case .estimate(let e):
            return .estimate(Estimate(burnKcal: e.burnKcal, rangeKcal: (e.burnKcal - e.errorKcal)...(e.burnKcal + e.errorKcal),
                                      strapKcal: e.strapKcal, completeDays: e.completeDays, trendKgPerWeek: e.trendKgPerWeek))
        case .missing(let days, _, let weighs, _, _):
            return .missing(completeDays: days, weighIns: weighs)
        }
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
