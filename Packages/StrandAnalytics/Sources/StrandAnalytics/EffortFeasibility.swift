import Foundation

// EffortFeasibility.swift — what a PLANNED session is actually worth in Effort.
//
// Exists because a coach prescribed "a 20-minute Zone 2 ride, effort 15", which is arithmetically
// impossible: held in Zone 2 for 20 minutes, NOOP's own Effort maths cannot produce a number that low.
// Nothing checked, because nothing could — `propose_plan` took `target_effort` as a free number and the
// model had never been told the relation between a duration, an intensity and the resulting score.
//
// The confusion underneath is that NOOP has TWO zone models, and only one of them feeds Effort:
//
//   * DISPLAY zones (`HRZones`) are % of HRmax. They are what the wearer sees, what the live readout
//     colours, and what a coach means by "Zone 2". They are also now user-definable.
//   * EFFORT zones (`StrainScorer`, Edwards) are % of heart-rate RESERVE — (HR − resting) / (max −
//     resting) — with fixed 50/60/70/80/90 thresholds that are part of the published method.
//
// Those two disagree, and the gap is not small: with HRmax 190 and a resting HR of 50, the bottom of
// display Zone 2 (60 % HRmax = 114 bpm) is only 46 % HRR, which Edwards weights ZERO, while the top
// (70 % HRmax = 133 bpm) is 59 % HRR and weights 1. So a session prescribed in display zones lands on
// an Edwards weight the model has no way to guess.
//
// This file closes that gap by evaluating the SHIPPED maths at the planned intensity rather than
// modelling it again: Edwards weight × minutes → `StrainScorer.trimpToStrain`. Same weights, same
// log map, same denominator. It is deliberately NOT done by synthesising a fake HR stream and calling
// `StrainScorer.strain`, because that path refuses anything under ~10 minutes of data — a sensible
// guard against trusting a thin real stream, and meaningless for a hypothetical.
public enum EffortFeasibility {

    /// What a session held inside one zone would score.
    ///
    /// Three figures rather than two, because the honest span is too wide to prescribe against. A
    /// DISPLAY band can straddle an Edwards threshold: with HRmax 190 and resting 50, the floor of
    /// Zone 2 is 46 % HRR — below Edwards' 50 % cut-off — so a session pinned to the very bottom edge
    /// scores a true zero, while the same session a few beats higher scores in the thirties. Both are
    /// real. Quoting the zero as "what Zone 2 is worth" would be as misleading as the 15 that started
    /// this, so `typical` is what gets prescribed and `low`/`high` are there to explain the spread.
    public struct Range: Equatable, Sendable {
        /// Effort if the whole session sat at the very BOTTOM of the zone. Can be 0 — see above.
        public let low: Double
        /// Effort for a session spread ACROSS the band, which is how sessions are actually ridden.
        /// What a plan should target.
        public let typical: Double
        /// Effort if it sat at the TOP.
        public let high: Double

        public init(low: Double, typical: Double, high: Double) {
            self.low = low
            self.typical = typical
            self.high = high
        }

        /// Whether a proposed figure is physically reachable at all for this session.
        public func contains(_ effort: Double) -> Bool { effort >= low && effort <= high }

        /// The nearest reachable figure to `effort`.
        public func clamped(_ effort: Double) -> Double { Swift.min(Swift.max(effort, low), high) }

        /// How far a proposed figure sits from what the session typically scores, in Effort points.
        public func distanceFromTypical(_ effort: Double) -> Double { abs(effort - typical) }
    }

    /// How far a model-supplied target may sit from `typical` before the app overrides it. Generous on
    /// purpose: the point is to catch "15 for a session worth 34", not to police a coach's judgement
    /// about a wearer riding the easy end of a band. Five points is well inside one Edwards step at
    /// any realistic duration, so a deliberate lean stays intact while an arithmetic impossibility
    /// does not.
    public static let targetTolerance: Double = 5.0

    /// The Effort a session of `minutes` spent between `zoneLowerBpm` and `zoneUpperBpm` would earn.
    ///
    /// Returns nil for a session with no duration or an unusable heart-rate reserve (max ≤ resting),
    /// so a caller can stay quiet rather than quote a number built on nothing.
    ///
    /// The bounds come from the wearer's OWN bands (`HRZoneSet`), which is why this landed after the
    /// custom-zones work: checking a Zone 2 prescription against textbook bands would be a different
    /// check from the session they will actually ride.
    ///
    /// Note the range is usually wide, and honestly so — a zone is a band, not a heart rate, and where
    /// you sit inside it can be the difference between one Edwards weight and the next. Quoting a
    /// single number would be false precision.
    public static func sessionEffortRange(zoneLowerBpm: Double,
                                          zoneUpperBpm: Double,
                                          minutes: Double,
                                          restingHR: Double,
                                          hrMax: Double) -> Range? {
        guard minutes > 0, hrMax > restingHR else { return nil }
        let reserve = hrMax - restingHR
        // The top of a band is exclusive everywhere else in the app, so evaluate just inside it rather
        // than at the boundary the next zone owns.
        let topInside = Swift.max(zoneLowerBpm, zoneUpperBpm - 1)

        func effort(atWeight weight: Double) -> Double {
            StrainScorer.trimpToStrain(weight * minutes)
        }
        func weight(at bpm: Double) -> Double {
            Double(StrainScorer.zoneWeight(bpm, restingHR: restingHR, hrReserve: reserve))
        }

        // `typical` uses the MEAN Edwards weight across the band, not the weight at its midpoint.
        // Sampling one point puts the whole answer on the wrong side of a step function whenever the
        // band spans an Edwards threshold — with HRmax 187 and resting 60, the midpoint of display
        // Zone 2 is 48 % HRR, so a midpoint reading called a 20-minute ride worth exactly nothing.
        // Averaging models what actually happens instead: nobody holds one heart rate for 20 minutes,
        // they range across the band, and the score follows the share of time above each threshold.
        var weightSum = 0.0
        for i in 0..<Self.bandSamples {
            let t = (Double(i) + 0.5) / Double(Self.bandSamples)   // midpoints, so neither edge dominates
            weightSum += weight(at: zoneLowerBpm + t * (topInside - zoneLowerBpm))
        }
        let meanWeight = weightSum / Double(Self.bandSamples)

        return Range(low: effort(atWeight: weight(at: zoneLowerBpm)),
                     typical: effort(atWeight: meanWeight),
                     high: effort(atWeight: weight(at: topInside)))
    }

    /// How finely the band is sampled for the mean weight. The Edwards weight is a step function of
    /// %HRR, so this only has to resolve where the steps fall inside one band — 256 slices puts that
    /// error far below a tenth of an Effort point at any realistic band width, and the whole loop is a
    /// few hundred nanoseconds.
    static let bandSamples = 256

    /// The same question asked in the wearer's own zone numbering. `zone` is 1...5 against `zoneSet`.
    public static func sessionEffortRange(zone: Int,
                                          minutes: Double,
                                          zoneSet: HRZoneSet,
                                          restingHR: Double) -> Range? {
        guard zone >= 1, zone <= zoneSet.zones.count else { return nil }
        let band = zoneSet.zones[zone - 1]
        return sessionEffortRange(zoneLowerBpm: band.lower, zoneUpperBpm: band.upper,
                                  minutes: minutes, restingHR: restingHR, hrMax: zoneSet.maxHR)
    }

    /// One line stating what the session is worth, for the coach's context and the tool's reply — so
    /// both quote the identical arithmetic instead of the model paraphrasing a number back. Leads with
    /// the typical figure (what to prescribe) and only mentions the spread when there is one.
    public static func sentence(zone: Int, minutes: Double, range: Range) -> String {
        let mins = minutes.rounded()
        if range.low == range.high {
            return String(format: "%.0f min in Zone %d is worth about %.0f Effort.", mins, zone, range.typical)
        }
        return String(format: "%.0f min in Zone %d is worth about %.0f Effort (%.0f–%.0f depending on "
                      + "where in the band it sits).",
                      mins, zone, range.typical, range.low, range.high)
    }
}
