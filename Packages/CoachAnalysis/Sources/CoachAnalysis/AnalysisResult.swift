import Foundation

/// One statistical test an analysis ran. Every test counts toward the multiple-testing correction of the
/// answer it belongs to, whatever it found.
public struct AnalysisTest: Equatable, Sendable {
    /// What was estimated, e.g. "Evening − Morning" or "Spearman ρ".
    public let label: String
    public let estimate: Double
    public let lower: Double
    public let upper: Double
    public let p: Double
    public let n: Int
    /// Hedges' g for a difference in means, when it could be computed.
    public let effectSize: Double?
    /// Whether the estimate is in the metric's own unit (a difference) or unitless (a correlation).
    public let inMetricUnit: Bool
}

/// What an analysis found, before it is rendered for the model or the wearer.
public struct AnalysisResult: Equatable, Sendable {
    public let operation: AnalysisSpec.Operation
    public let plan: String
    public let windowFrom: String
    public let windowTo: String
    public let metricLabel: String
    public let unit: String?
    /// Plain facts, one per line (group sizes and means, coverage, ranked days).
    public var facts: [String]
    public var tests: [AnalysisTest]
    /// Other measured differences between the compared days that could explain part of a result.
    public var confounders: [String]
    /// Limits of the data: too few days, gaps, excluded overlaps.
    public var notes: [String]
}

enum AnalysisFormat {
    /// Precision follows magnitude, the way the Coach's existing history blocks print numbers.
    static func number(_ value: Double) -> String {
        let decimals = abs(value) >= 100 ? 0 : (abs(value) >= 10 ? 1 : 2)
        return String(format: "%.*f", decimals, value)
    }

    static func signed(_ value: Double) -> String {
        (value > 0 ? "+" : "") + number(value)
    }

    /// "p < 0.001" / "p = 0.042" — the relation is part of the value, so `name` carries it.
    static func p(_ value: Double, name: String = "p") -> String {
        value < 0.001 ? "\(name) < 0.001" : "\(name) = " + String(format: "%.3f", value)
    }

    static func withUnit(_ text: String, _ unit: String?) -> String {
        unit.map { "\(text) \($0)" } ?? text
    }
}
