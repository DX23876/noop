import Foundation

// HealthspanPresentation.swift — what the Healthspan card shows beyond the age itself, derived from the same
// engine and inputs so it can never disagree with the headline: totals per domain, the strongest realistic
// next steps ("levers"), and the half-year projection that Pace of Aging stands for.

/// The three groups of components.
public enum HealthspanDomain: String, CaseIterable, Sendable { case sleep, activity, fitness }

extension HealthspanEngine.Component {
    public var domain: HealthspanDomain {
        switch self {
        case .sleepDuration, .sleepConsistency: return .sleep
        case .dailySteps, .zone13, .zone45, .strength: return .activity
        case .vo2max, .restingHR, .leanMass: return .fitness
        }
    }
}

extension HealthspanEngine.Result {
    /// Years one domain adds (positive) or removes (negative); the three add up to `deltaYears`.
    public func years(in domain: HealthspanDomain) -> Double {
        contributions.filter { $0.component.domain == domain }.reduce(0) { $0 + $1.years }
    }
}

extension HealthspanEngine {

    /// One realistic next step for a component and what it would change the age by (negative = younger).
    public struct Lever: Equatable, Sendable {
        public let component: Component
        public let currentValue: Double
        public let newValue: Double
        public let years: Double
    }

    /// The step a person could plausibly take within weeks, or nil once the curve gives nothing more.
    /// Sizes are a design choice for the card, not a finding: half an hour of sleep, 10 consistency points,
    /// 1000 steps, 30 / 10 / 20 weekly minutes, 3 ml/kg/min of VO₂max, 3 bpm, 2 points of lean mass.
    static func nextStep(_ c: Component, value v: Double) -> Double? {
        switch c {
        case .sleepDuration: return v < 8 ? min(v + 0.5, 8) : nil
        case .sleepConsistency: return v < 89.8 ? min(v + 10, 100) : nil
        case .dailySteps: return v < 10_901 ? v + 1000 : nil
        case .zone13: return v < 600 ? v + 30 : nil
        case .zone45: return v < 53.6 ? v + 10 : nil
        case .strength: return v < 60 ? v + 20 : nil
        case .vo2max: return v + 3
        case .restingHR: return v > restingHRRange.lowerBound ? v - 3 : nil
        case .leanMass: return v + 2
        }
    }

    /// The strongest next steps, strongest first; only steps worth at least `minimumYears`.
    public static func levers(_ inputs: Inputs, limit: Int = 3, minimumYears: Double = 0.05) -> [Lever] {
        guard let now = compute(inputs) else { return [] }
        var out: [Lever] = []
        for c in Component.allCases {
            guard let v = inputs.value(c), let step = nextStep(c, value: v) else { continue }
            var after = inputs
            after.set(c, step)
            guard let then = compute(after) else { continue }
            let gain = then.deltaYears - now.deltaYears
            if gain <= -minimumYears { out.append(Lever(component: c, currentValue: v, newValue: step, years: gain)) }
        }
        return Array(out.sorted { $0.years < $1.years }.prefix(limit))
    }

    /// The age half a year from now at the current pace: Pace of Aging is (projected − current) / 0.5.
    public static func projectedAge(currentAge: Double, pace: Double) -> Double { currentAge + 0.5 * pace }
}

extension HealthspanEngine.Inputs {
    public mutating func set(_ c: HealthspanEngine.Component, _ v: Double?) {
        switch c {
        case .sleepDuration: sleepHours = v
        case .sleepConsistency: sleepConsistencyPct = v
        case .dailySteps: dailySteps = v
        case .zone13: zone13MinPerWeek = v
        case .zone45: zone45MinPerWeek = v
        case .strength: strengthMinPerWeek = v
        case .vo2max: vo2max = v
        case .restingHR: restingHR = v
        case .leanMass: leanMassPct = v
        }
    }
}
