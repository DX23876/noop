import Foundation

// ActivityEstimate: aggregate the ring's 0x50 activity_info MET stream into a clearly-labeled activity
// estimate (active minutes / MET-minutes / active energy). This is the HONEST activity metric — it is
// derived only from the already-decoded MET samples (OuraDecoders.decodeActivityInfo), never from a
// minted step count. The MET decode formula is third-party (see OuraActivityInfo) and NOT ground-truth-
// validated, so everything here stays Tier B: the app surfaces it as an estimate to validate against
// WHOOP active-kcal / Apple Health active energy, and it is never folded into scoring as truth.
//
// Platform-pure, database-free, value types only (builds on Linux). Facts per OURA_PROTOCOL.md s6.13.

/// A MET-derived activity estimate for a set of 0x50 samples (one window, one day, whatever the caller
/// buckets). Every field is an ESTIMATE; the two energy fields are nil when no body mass is supplied.
public struct OuraActivityEstimate: Equatable, Sendable {
    /// Number of MET samples aggregated (each 0x50 record contributes `met.count` of them).
    public let sampleCount: Int
    /// The per-sample epoch length assumed for the minute/energy totals. This is the ONE calibration
    /// unknown (the ring's raw MET cadence is unconfirmed); validating the totals against WHOOP / Apple
    /// Health is how it gets pinned. Carried on the estimate so a log line is self-describing.
    public let epochSeconds: Double
    /// Mean MET across all samples (cadence-independent — the cleanest cross-check value).
    public let meanMET: Double
    /// Peak MET across all samples (cadence-independent).
    public let maxMET: Double
    /// Σ metᵢ × epochMinutes — standard MET-minutes of activity.
    public let metMinutes: Double
    /// Minutes whose MET ≥ `moderateThresholdMET` (default 3.0 = moderate) — a "how long were you active"
    /// figure, = (count of qualifying samples) × epochMinutes.
    public let activeMinutes: Double
    /// Estimated ABOVE-RESTING energy: Σ max(metᵢ − 1, 0) × massKg × epochHours (kcal). This is the
    /// "active energy" convention WHOOP / Apple Health report (it excludes the 1-MET basal floor). nil
    /// without body mass.
    public let estActiveKcal: Double?
    /// Estimated GROSS energy: Σ metᵢ × massKg × epochHours (kcal), basal included. nil without body mass.
    public let estTotalKcal: Double?

    public init(sampleCount: Int, epochSeconds: Double, meanMET: Double, maxMET: Double,
                metMinutes: Double, activeMinutes: Double, estActiveKcal: Double?, estTotalKcal: Double?) {
        self.sampleCount = sampleCount
        self.epochSeconds = epochSeconds
        self.meanMET = meanMET
        self.maxMET = maxMET
        self.metMinutes = metMinutes
        self.activeMinutes = activeMinutes
        self.estActiveKcal = estActiveKcal
        self.estTotalKcal = estTotalKcal
    }
}

/// Pure MET-stream aggregation. No database, no CoreBluetooth, no clock — the caller decides which
/// samples belong to the window/day (using the UTC anchor) and passes them in.
public enum OuraActivityEstimator {
    /// Aggregate raw MET samples into an estimate. `epochSeconds` is the assumed per-sample duration
    /// (the calibration knob); `bodyMassKg` enables the energy fields; a sample counts as "active" when
    /// its MET reaches `moderateThresholdMET`. An empty input yields an all-zero estimate (never nil —
    /// "no activity" is a real answer). Scalars are rounded to 2 dp so a value compares exactly against
    /// a fixture (0.1 is not exactly representable in binary floating point).
    public static func estimate(metSamples: [Double],
                                epochSeconds: Double,
                                bodyMassKg: Double? = nil,
                                moderateThresholdMET: Double = 3.0) -> OuraActivityEstimate {
        let epochMinutes = epochSeconds / 60.0
        let epochHours = epochSeconds / 3600.0
        let count = metSamples.count

        let sum = metSamples.reduce(0, +)
        let mean = count > 0 ? sum / Double(count) : 0
        let peak = metSamples.max() ?? 0

        let metMinutes = sum * epochMinutes
        let activeCount = metSamples.reduce(into: 0) { acc, m in if m >= moderateThresholdMET { acc += 1 } }
        let activeMinutes = Double(activeCount) * epochMinutes

        let activeKcal: Double?
        let totalKcal: Double?
        if let mass = bodyMassKg {
            // Active = above-resting (subtract the 1-MET basal floor, clamped at 0 so a sub-resting
            // sample never contributes negative energy); total = gross including basal.
            let aboveResting = metSamples.reduce(0) { $0 + max($1 - 1.0, 0) }
            activeKcal = aboveResting * mass * epochHours
            totalKcal = sum * mass * epochHours
        } else {
            activeKcal = nil
            totalKcal = nil
        }

        func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
        return OuraActivityEstimate(
            sampleCount: count,
            epochSeconds: epochSeconds,
            meanMET: r2(mean),
            maxMET: r2(peak),
            metMinutes: r2(metMinutes),
            activeMinutes: r2(activeMinutes),
            estActiveKcal: activeKcal.map(r2),
            estTotalKcal: totalKcal.map(r2)
        )
    }

    /// Convenience over decoded 0x50 records: flattens every record's `met` series and aggregates.
    public static func estimate(from records: [OuraActivityInfo],
                                epochSeconds: Double,
                                bodyMassKg: Double? = nil,
                                moderateThresholdMET: Double = 3.0) -> OuraActivityEstimate {
        estimate(metSamples: records.flatMap { $0.met },
                 epochSeconds: epochSeconds,
                 bodyMassKg: bodyMassKg,
                 moderateThresholdMET: moderateThresholdMET)
    }
}
