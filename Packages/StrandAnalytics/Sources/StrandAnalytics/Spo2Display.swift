import Foundation

// Spo2Display.swift — which blood-oxygen number a surface shows, out of up to three.
//
// A wearer can hold all of these at once:
//
//   • a calibrated `spo2Pct` for the day on screen — a real measurement of that day;
//   • a calibrated `spo2Pct` CARRIED from an earlier day, deliberately with no staleness bound
//     (SpO₂ is sparse and often imported, so "last known, of any age" is the honest carry — the
//     bound `lastRespDay` applies exists because respiratory is nightly and SpO₂ is not);
//   • the strap's own nightly CANDIDATE mean for the day on screen, behind the default-off
//     experimental toggle, which is never written to `spo2Pct` and always labelled.
//
// The old rule was "any calibrated value beats the candidate". That is right between a measurement
// and an estimate OF THE SAME DAY and wrong across days, and it was reported as such: an import
// ending on 1 June kept the tile pinned to a 1 June figure for three and a half months while the
// strap produced a fresh estimate every night — which the rule then suppressed, because a
// calibrated value existed somewhere in the past.
//
// So the order is by RECENCY first and strength second: today's measurement, else today's estimate,
// else the old measurement. The estimate only ever displaces a reading from an EARLIER day, never
// one from the day being shown, and it never loses its label on the way.
public enum Spo2Display {

    /// What the shown number is, so a surface can caption it. The distinction between the two
    /// measured cases is not cosmetic: one is the day on screen, the other is a carry that the
    /// surface stamps with its own date.
    public enum Provenance: Equatable, Sendable {
        /// A calibrated reading for the day being shown.
        case measured
        /// A calibrated reading carried from an earlier day.
        case measuredCarried
        /// The strap's nightly candidate for the day being shown. Always labelled "strap estimate
        /// (unverified)" — it is not a validated calibration on either WHOOP or Oura.
        case candidate
    }

    public struct Resolved: Equatable, Sendable {
        public let percent: Double
        public let provenance: Provenance

        public init(percent: Double, provenance: Provenance) {
            self.percent = percent
            self.provenance = provenance
        }
    }

    /// - Parameters:
    ///   - todayPct: calibrated `spo2Pct` for the day on screen.
    ///   - candidatePct: the strap candidate for that same day, or nil when there is none.
    ///   - candidateEnabled: the experimental toggle. Off means the candidate does not exist as far
    ///     as this decision is concerned — not that it loses a tie.
    ///   - carriedPct: the freshest calibrated reading from an EARLIER day.
    public static func resolve(todayPct: Double?,
                               candidatePct: Double?,
                               candidateEnabled: Bool,
                               carriedPct: Double?) -> Resolved? {
        if let todayPct, todayPct.isFinite, todayPct > 0 {
            return Resolved(percent: todayPct, provenance: .measured)
        }
        if candidateEnabled, let candidatePct, candidatePct.isFinite, candidatePct > 0 {
            return Resolved(percent: candidatePct, provenance: .candidate)
        }
        if let carriedPct, carriedPct.isFinite, carriedPct > 0 {
            return Resolved(percent: carriedPct, provenance: .measuredCarried)
        }
        return nil
    }
}
