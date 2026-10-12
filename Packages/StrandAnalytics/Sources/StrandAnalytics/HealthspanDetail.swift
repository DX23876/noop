import Foundation

// HealthspanDetail.swift — the pure parts of the Healthspan detail screen: the fixed scale and coloured ticks
// of each measure's bar, Pace of Aging in the paper's four bands, and which status line to show. Everything
// is read off the engine, so a bar, its marker and its figure cannot disagree.

extension HealthspanEngine {

    /// Ticks per bar; the UI colours each tick by the years its value would add or remove.
    public static let barTickCount = 41

    public struct BarScale: Equatable, Sendable {
        public let range: ClosedRange<Double>
        /// Evenly spaced from the low to the high end; `years` is the component's contribution at `value`.
        public let ticks: [(value: Double, years: Double)]

        public static func == (a: BarScale, b: BarScale) -> Bool {
            a.range == b.range && a.ticks.elementsEqual(b.ticks) { $0.value == $1.value && $0.years == $1.years }
        }

        /// Where a value sits on the bar, 0…1, held at the ends.
        public func position(_ v: Double) -> Double {
            min(1, max(0, (v - range.lowerBound) / (range.upperBound - range.lowerBound)))
        }
    }

    /// The bar range for a measure: wide enough to show where the target and the curve's end sit, over the
    /// span of values most adults fall in (sleep 4–10 h, steps 0–16K, strength 0–2.5 h).
    static func barRange(_ c: Component, age: Double, sex: Sex) -> ClosedRange<Double> {
        switch c {
        case .sleepDuration: return 4...10
        case .sleepConsistency: return 30...100
        case .dailySteps: return 0...16_000
        case .zone13: return 0...600
        case .zone45: return 0...120
        case .strength: return 0...150
        case .vo2max:
            let t = target(.vo2max, age: age, sex: sex).rounded()
            return max(10, t - 20)...(t + 20)
        case .restingHR: return 40...90
        case .leanMass: return 40...95
        }
    }

    public static func barScale(_ c: Component, age: Double, sex: Sex) -> BarScale {
        let range = barRange(c, age: age, sex: sex)
        let t = target(c, age: age, sex: sex)
        let ticks = (0..<barTickCount).map { i -> (value: Double, years: Double) in
            let v = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / Double(barTickCount - 1)
            return (v, overlapFactor * rawYears(c, value: v, target: t))
        }
        return BarScale(range: range, ticks: ticks)
    }

    /// The paper's four Pace of Aging bands.
    public enum PaceClass: Equatable, Sendable {
        case reversing, slowing, steady, accelerating
        public init(pace: Double) {
            if pace < 0 { self = .reversing }
            else if pace < 0.95 { self = .slowing }
            else if pace <= 1.05 { self = .steady }
            else { self = .accelerating }
        }
    }

    /// Which status line the screen leads with, and the measures it names.
    public struct Narrative: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case reversing, youngerSteady, youngerAccelerating, olderImproving, olderAccelerating
        }
        public let kind: Kind
        /// The measure removing the most years, if any removes years.
        public let helper: Component?
        /// The strongest next step, if there is one.
        public let lever: Component?
    }

    /// A pace below zero leads, whatever the delta: the age is falling. Otherwise younger or on target pairs
    /// with a pace at or below the calendar as steady; older pairs with a pace below the calendar as improving.
    /// Without a pace yet, the delta alone decides and nothing is "accelerating".
    public static func narrative(result: Result, pace: Double?, levers: [Lever]) -> Narrative {
        let accelerating = pace.map { PaceClass(pace: $0) == .accelerating } ?? false
        let kind: Narrative.Kind
        if let pace, PaceClass(pace: pace) == .reversing {
            kind = .reversing
        } else if result.deltaYears <= 0 {
            kind = accelerating ? .youngerAccelerating : .youngerSteady
        } else {
            kind = accelerating ? .olderAccelerating : .olderImproving
        }
        let helper = result.contributions.filter { $0.years < -0.05 }.min { $0.years < $1.years }?.component
        return Narrative(kind: kind, helper: helper, lever: levers.first?.component)
    }

    /// How the last 30 days stand against the six months for one measure, when the difference matters.
    public struct Trend: Equatable, Sendable {
        /// The recent value is higher than the six-month one.
        public let rising: Bool
        /// The recent value would take years off compared with the six-month one.
        public let better: Bool
    }

    /// Smallest change in a measure's years worth an arrow.
    public static let trendThresholdYears = 0.1

    /// The trend arrow for a measure: the direction its value moved and whether that helps, shown only when
    /// the recent value would move its years by at least `trendThresholdYears`.
    public static func trend(windowValue: Double, recentValue: Double, windowYears: Double,
                             recentYears: Double) -> Trend? {
        let shift = recentYears - windowYears
        guard abs(shift) >= trendThresholdYears, recentValue != windowValue else { return nil }
        return Trend(rising: recentValue > windowValue, better: shift < 0)
    }
}
