import Foundation

/// The real burn from food and weight, the one scale reading of it (owner decisions 2026-11-27, Q20 and Q21).
///
/// Two scale estimates existed (`DietExpenditure` on the Food page, `AdaptiveExpenditureEngine` on the Energy
/// page) and could disagree. This is the one both read: eaten on the days the wearer marked as completely logged,
/// less the energy the weight trend stored or released, over eight weeks. The trend is Theil–Sen over weigh-ins at
/// least seven days apart, after a gate against the smoothed series, so a water swing cannot become a burn.
/// Weigh-ins with a water mark (creatine, period, salty food, a new medicine) are left out by the caller.
///
/// Water is still the largest error: one unexplained kilogram moves an eight-week figure by about 140 kcal a day
/// (four weeks: about 275), so a figure is only offered when its own uncertainty is under 10 % of the burn.
public enum ScaleBurn {
    public static let windowDays = 56
    /// The data must span six weeks before a figure is offered at all.
    public static let minimumSpanDays = 42
    public static let minimumCompleteDays = 21
    /// Completely logged days must fall in at least this many distinct weeks.
    public static let minimumWeeks = 6
    public static let minimumWeighIns = 10
    public static let maximumRelativeError = 0.10

    /// What a figure needs before it is offered (`full`), or before an early look at its direction is shown
    /// (`early`, owner 2026-11-27: after three weeks). An early look is never proposed and never applied.
    public struct Gates: Equatable, Sendable {
        public var spanDays: Int, completeDays: Int, weeks: Int, weighIns: Int, relativeError: Double
        public static let full = Gates(spanDays: minimumSpanDays, completeDays: minimumCompleteDays, weeks: minimumWeeks,
                                       weighIns: minimumWeighIns, relativeError: maximumRelativeError)
        public static let early = Gates(spanDays: 21, completeDays: 12, weeks: 3, weighIns: 6, relativeError: 0.20)
    }

    public struct Estimate: Equatable, Sendable {
        public var burnKcal: Double
        /// One standard error of `burnKcal`.
        public var errorKcal: Double
        /// The strap's mean over the same completely logged days, before any scale correction.
        public var strapKcal: Double?
        public var completeDays: Int
        public var weighIns: Int
        public var trendKgPerWeek: Double
        public var relativeError: Double { burnKcal > 0 ? errorKcal / burnKcal : .infinity }
        /// Real burn over the strap's, when the strap measured the same days.
        public var ratio: Double? { strapKcal.flatMap { $0 > 0 ? burnKcal / $0 : nil } }
    }

    public enum Outcome: Equatable, Sendable {
        case estimate(Estimate)
        /// Not enough yet, or too uncertain: what there is, against what is needed.
        case missing(completeDays: Int, weeks: Int, weighIns: Int, spanDays: Int, tooUncertain: Bool)
    }

    /// `completeIntake` holds only the days marked as completely logged, `weighIns` only unmarked weigh-ins,
    /// `strapByDay` the strap's burn per day before any scale correction. Today and later are left out.
    public static func estimate(completeIntake: [String: Double], weighIns: [(day: String, kg: Double)],
                                strapByDay: [String: Double], today: String, kcalPerKg: Double,
                                gates: Gates = .full, calendar: Calendar = .current) -> Outcome {
        func date(_ day: String) -> Date? {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        guard let end = date(today), let start = calendar.date(byAdding: .day, value: -windowDays, to: end) else {
            return .missing(completeDays: 0, weeks: 0, weighIns: 0, spanDays: 0, tooUncertain: false)
        }
        func inWindow(_ day: String) -> Date? {
            guard let d = date(day), d >= start, d < end else { return nil }
            return d
        }
        let intake = completeIntake.compactMap { day, kcal -> (day: String, date: Date, kcal: Double)? in
            guard kcal.isFinite, (500...10_000).contains(kcal), let d = inWindow(day) else { return nil }
            return (day, d, kcal)
        }
        var byDay: [Date: Double] = [:]
        for w in weighIns where w.kg.isFinite && (25...350).contains(w.kg) {
            if let d = inWindow(w.day) { byDay[d] = w.kg }
        }
        let weights = byDay.sorted { $0.key < $1.key }.map { (date: $0.key, kg: $0.value) }
        var weekKeys = Set<String>()
        for entry in intake {
            let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: entry.date)
            weekKeys.insert("\(parts.yearForWeekOfYear ?? 0)-\(parts.weekOfYear ?? 0)")
        }
        let firstDates = [intake.map(\.date).min(), weights.first?.date].compactMap { $0 }
        let lastDates = [intake.map(\.date).max(), weights.last?.date].compactMap { $0 }
        let span = firstDates.count == 2 && lastDates.count == 2
            ? (calendar.dateComponents([.day], from: firstDates.max()!, to: lastDates.min()!).day ?? 0) + 1 : 0
        let missing = Outcome.missing(completeDays: intake.count, weeks: weekKeys.count, weighIns: weights.count,
                                      spanDays: max(0, span), tooUncertain: false)
        guard intake.count >= gates.completeDays, weekKeys.count >= gates.weeks, weights.count >= gates.weighIns,
              span >= gates.spanDays else { return missing }

        // A weigh-in far from the smoothed trend (more than 4 % or 3 kg) is left out before the slope.
        var smoothed: Double?
        var gated: [(date: Date, kg: Double)] = []
        for w in weights {
            let centre = smoothed ?? w.kg
            if abs(w.kg - centre) <= max(3, centre * 0.04) { gated.append(w) }
            smoothed = 0.25 * w.kg + 0.75 * centre
        }
        var slopes: [Double] = []
        for i in 0..<gated.count {
            for j in (i + 1)..<gated.count {
                let days = calendar.dateComponents([.day], from: gated[i].date, to: gated[j].date).day ?? 0
                guard days >= 7 else { continue }
                slopes.append((gated[j].kg - gated[i].kg) / Double(days))
            }
        }
        guard let slope = median(slopes) else { return missing }
        let kcals = intake.map(\.kcal)
        let eaten = kcals.reduce(0, +) / Double(kcals.count)
        let burn = eaten - slope * kcalPerKg
        // The pair slopes share their weigh-ins, so they are far from independent: the error is counted per
        // weigh-in, not per pair, or a handful of readings would claim the certainty of hundreds.
        let mad = median(slopes.map { abs($0 - slope) }) ?? 0
        let slopeError = 1.4826 * mad / sqrt(Double(max(1, gated.count))) * kcalPerKg
        let intakeError = standardDeviation(kcals) / sqrt(Double(kcals.count))
        let error = hypot(slopeError, intakeError)
        let strapDays = intake.compactMap { strapByDay[$0.day] }.filter { $0.isFinite && $0 > 0 }
        let strap = strapDays.isEmpty ? nil : strapDays.reduce(0, +) / Double(strapDays.count)
        let estimate = Estimate(burnKcal: burn, errorKcal: error, strapKcal: strap, completeDays: intake.count,
                                weighIns: weights.count, trendKgPerWeek: slope * 7)
        guard burn.isFinite, burn > 800, estimate.relativeError <= gates.relativeError else {
            return .missing(completeDays: intake.count, weeks: weekKeys.count, weighIns: weights.count,
                            spanDays: span, tooUncertain: true)
        }
        return .estimate(estimate)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1))
    }
}

/// The personal correction of the strap's burn from the scale (owner decisions 2026-11-27, Q10, Q13, Q14, Q22,
/// Q23): offered once with the scale's figure beside the strap's, then kept and moved by at most 3 % a week, never
/// beyond ±20 %, held still while a known disturbance settles, and visible and switchable off at any time.
///
/// With a measured resting rate the correction leaves basal alone and moves everyday, movement and training only;
/// without one it moves the whole day. It applies from the day the wearer agreed, never to the days before.
public struct BurnCorrection: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case none, proposed, active, declined, off }

    public var status: Status = .none
    /// The factor in use while active (`appliesToBasal` says on what).
    public var factor: Double = 1
    /// The factor the scale currently points to, shown with a proposal.
    public var targetFactor: Double?
    public var sinceDay: String?
    public var lastUpdatedDay: String?
    public var declinedDay: String?
    /// Whether the factor covers basal too (no measured resting rate when it was set up).
    public var appliesToBasal: Bool = true

    public static let range: ClosedRange<Double> = 0.8...1.2
    public static let weeklyStep = 0.03
    /// A scale that differs from the strap by less than this is not worth a proposal.
    public static let proposeFrom = 0.03
    /// A declined proposal returns after this long.
    public static let declinedForDays = 56

    public init() {}

    /// The factor that brings the strap's day to the scale's: on the whole day, or with a measured resting rate
    /// on everything but basal, `basalShare` being basal's share of the strap's day. Capped so the day moves
    /// by at most ±20 %.
    public static func target(ratio: Double, basalShare: Double?) -> Double {
        let total = min(range.upperBound, max(range.lowerBound, ratio))
        guard let basalShare, basalShare > 0, basalShare < 0.95 else { return total }
        return 1 + (total - 1) / (1 - basalShare)
    }

    /// The state after the scale was read again on `today`. `holding` is true while a known disturbance settles.
    /// `basalShare` is basal's share of the strap's day, whatever the formula: an active correction whose basis
    /// changed (a measured resting rate set or removed since it was agreed) is carried over to the new basis with it.
    public func evaluated(target: Double?, today: String, holding: Bool, measured: Bool,
                          basalShare: Double? = nil, calendar: Calendar = .current) -> BurnCorrection {
        var next = self
        if status == .active, appliesToBasal == measured {
            next = rebased(coversBasal: !measured, basalShare: basalShare)
            guard next.status == .active else { return next.evaluated(target: target, today: today, holding: holding,
                                                                        measured: measured, calendar: calendar) }
        }
        return next.stepped(target: target, today: today, holding: holding, measured: measured, calendar: calendar)
    }

    /// An active correction moved to the other basis with the same kilocalories: a factor on the whole day becomes
    /// the factor on everything but basal that adds as much, and back. Without a usable share it starts again as a
    /// fresh proposal rather than apply a factor fitted on the other basis (2026-11-28 review).
    func rebased(coversBasal: Bool, basalShare: Double?) -> BurnCorrection {
        var next = self
        guard let basalShare, basalShare > 0, basalShare < 0.95 else {
            next.status = .none
            next.factor = 1
            next.sinceDay = nil
            next.lastUpdatedDay = nil
            next.appliesToBasal = coversBasal
            return next
        }
        let rest = 1 - basalShare
        let carried = coversBasal ? 1 + (factor - 1) * rest : 1 + (factor - 1) / rest
        next.appliesToBasal = coversBasal
        next.factor = min(Self.upper(coversBasal), max(Self.lower(coversBasal), carried))
        return next
    }

    private func stepped(target: Double?, today: String, holding: Bool, measured: Bool,
                         calendar: Calendar) -> BurnCorrection {
        var next = self
        switch status {
        case .off:
            return next
        case .none, .declined:
            guard let target, !holding, abs(target - 1) >= Self.proposeFrom else { return next }
            if status == .declined, let declined = declinedDay,
               Self.days(from: declined, to: today, calendar: calendar).map({ $0 < Self.declinedForDays }) ?? true {
                return next
            }
            next.status = .proposed
            next.targetFactor = target
            next.appliesToBasal = !measured
        case .proposed:
            next.targetFactor = target
            next.appliesToBasal = !measured
        case .active:
            next.targetFactor = target
            guard let target, !holding else { return next }
            if let last = lastUpdatedDay, (Self.days(from: last, to: today, calendar: calendar) ?? 0) < 7 { return next }
            let step = min(Self.weeklyStep, max(-Self.weeklyStep, target - factor))
            next.factor = min(Self.upper(appliesToBasal), max(Self.lower(appliesToBasal), factor + step))
            next.lastUpdatedDay = today
        }
        return next
    }

    /// The wearer agreed: the proposal starts at the scale's factor, within the range, from today.
    public func accepted(today: String) -> BurnCorrection {
        var next = self
        next.status = .active
        next.factor = min(Self.upper(appliesToBasal), max(Self.lower(appliesToBasal), targetFactor ?? 1))
        next.sinceDay = today
        next.lastUpdatedDay = today
        return next
    }

    public func declined(today: String) -> BurnCorrection {
        var next = self
        next.status = .declined
        next.declinedDay = today
        return next
    }

    /// Switched off: the correction stops, days are shown as the strap measured them again.
    public func turnedOff() -> BurnCorrection {
        var next = self
        next.status = .off
        return next
    }

    /// Switched on again after being off: a fresh proposal on the next read.
    public func turnedOn() -> BurnCorrection {
        var next = self
        next.status = .none
        return next
    }

    /// The factor `day` is shown with, or nil when none applies to it.
    public func factor(on day: String) -> Double? {
        guard status == .active, let sinceDay, day >= sinceDay else { return nil }
        return factor
    }

    static func upper(_ basal: Bool) -> Double { basal ? range.upperBound : 1.5 }
    static func lower(_ basal: Bool) -> Double { basal ? range.lowerBound : 0.5 }

    static func days(from: String, to: String, calendar: Calendar) -> Int? {
        func date(_ day: String) -> Date? {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        guard let a = date(from), let b = date(to) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }

    public func encodedJSON() -> String {
        guard let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    public static func decode(_ json: String?) -> BurnCorrection {
        guard let data = json?.data(using: .utf8),
              let value = try? JSONDecoder().decode(BurnCorrection.self, from: data) else { return BurnCorrection() }
        return value
    }
}
