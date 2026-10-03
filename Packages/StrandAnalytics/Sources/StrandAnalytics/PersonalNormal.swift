import Foundation

/// How today's value of a nightly vital stands against the wearer's own recent normal: the shared rule
/// behind the "+4 vs. your usual" read-outs on Today.
///
/// The normal is the plain mean of up to the last `window` prior values, and the comparison is only
/// offered once `Baselines.minNightsSeed` of them exist, the same threshold at which a baseline is
/// provisionally trusted elsewhere. A change counts as notable when it lies more than one standard
/// deviation of those values away; smaller wobbles are reported but not coloured, so ordinary
/// night-to-night noise never reads as a signal.
public enum PersonalNormal {
    /// Which direction is good for a metric, if either.
    public enum Polarity: Sendable {
        case higherIsBetter, lowerIsBetter, neutral
    }

    /// How a notable change should be read.
    public enum Tone: Equatable, Sendable {
        /// Within ordinary variation, or a metric with no good direction.
        case ordinary
        case favourable
        case unfavourable
    }

    public struct Comparison: Equatable, Sendable {
        /// Today minus the personal normal, in the metric's own unit.
        public let delta: Double
        public let normal: Double
        public let tone: Tone
    }

    public static let window = 30

    /// Nil until enough prior values exist to call anything "usual".
    public static func compare(today: Double, prior: [Double], polarity: Polarity) -> Comparison? {
        let recent = Array(prior.suffix(window)).filter(\.isFinite)
        guard today.isFinite, recent.count >= Baselines.minNightsSeed else { return nil }
        let mean = recent.reduce(0, +) / Double(recent.count)
        let variance = recent.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(recent.count)
        let spread = variance.squareRoot()
        let delta = today - mean
        let notable = spread > 0 && abs(delta) > spread
        let tone: Tone
        switch (notable, polarity) {
        case (false, _), (_, .neutral): tone = .ordinary
        case (true, .higherIsBetter): tone = delta > 0 ? .favourable : .unfavourable
        case (true, .lowerIsBetter): tone = delta < 0 ? .favourable : .unfavourable
        }
        return Comparison(delta: delta, normal: mean, tone: tone)
    }

    /// "+4", "-1", "±0" (or "+0.6" with one decimal). Locale-independent digits like the tile values.
    public static func signedText(_ delta: Double, decimals: Int = 0) -> String {
        let scale = pow(10.0, Double(decimals))
        let rounded = (delta * scale).rounded(.toNearestOrAwayFromZero) / scale
        if rounded == 0 { return "±0" }
        let body = decimals == 0
            ? String(Int(abs(rounded)))
            : String(format: "%.\(decimals)f", abs(rounded))
        return (rounded > 0 ? "+" : "-") + body
    }
}
