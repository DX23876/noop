import Foundation
import WhoopStore

// ScoreConfidence.swift — per-score certainty tier for Charge / Effort / Rest.
//
// Each daily score rides a confidence tier so a sparse 5/MG day (or a cold-start
// baseline) reads truthfully instead of faking a number. Surfaced as a small
// label/dot under each score; the score itself stays nil-honest where it can't
// compute at all.
//
// Tiers (ordered lowest → highest):
//   .calibrating — the baseline/seed isn't usable yet, or the core input window is
//                  absent (no HR window for Effort, no in-bed data for Rest, HRV
//                  baseline not yet usable for Charge). The number, if shown, is a
//                  placeholder.
//   .building    — usable but thin: enough to compute, but the baseline is still
//                  provisional or the inputs are partial (e.g. a day backed mostly by
//                  PPG-derived HR, or a short baseline history).
//   .solid       — full inputs present and the baseline is trusted.
//
// Kept deliberately small and dependency-free so the Kotlin mirror is byte-identical.
public enum ScoreConfidence: String, Equatable, Sendable, Codable {
    case calibrating
    case building
    case solid

    // MARK: - Derivations (one per score; mirror the Android helpers exactly)

    /// Charge (recovery) confidence.
    /// - calibrating: no score (HRV baseline not usable / cold-start) → the number is absent.
    /// - solid:       a score exists AND the HRV baseline is fully trusted.
    /// - building:    a score exists but the HRV baseline is only provisional.
    public static func charge(recovery: Double?, hrvBaseline: BaselineState?) -> ScoreConfidence {
        guard recovery != nil, let b = hrvBaseline, b.usable else { return .calibrating }
        return b.trusted ? .solid : .building
    }

    /// Readiness confidence from the HRV/RHR baseline density backing the read (readiness is HRV-led).
    /// - calibrating: no read (insufficient history — the readiness level is `.insufficient`).
    /// - solid:       a read exists AND the full baseline window is present.
    /// - building:    a read exists but the baseline is shorter than the full window (e.g. 7–29 of 30).
    public static func readiness(hasRead: Bool, baselineNights: Int, fullWindow: Int) -> ScoreConfidence {
        guard hasRead else { return .calibrating }
        return baselineNights >= fullWindow ? .solid : .building
    }

    /// Effort (strain) confidence.
    /// - calibrating: no score (no usable HR window) → absent.
    /// - solid:       a score exists AND the HR window is dense (≥ solidReadings samples).
    /// - building:    a score exists but the HR window is thin (PPG-backed / short day).
    public static let solidEffortReadings: Int = 3600  // ~1 h at 1 Hz of HR coverage
    public static func effort(strain: Double?, hrSampleCount: Int) -> ScoreConfidence {
        guard strain != nil else { return .calibrating }
        return hrSampleCount >= solidEffortReadings ? .solid : .building
    }

    /// Rest (sleep) confidence.
    /// - calibrating: no in-bed data (no matched session) → absent.
    /// - solid:       a session exists AND every Rest component had real input
    ///                (staged sleep present so restorative + efficiency are real).
    /// - building:    a session exists but stages/inputs are partial.
    public static func rest(hasSession: Bool, hasStagedSleep: Bool) -> ScoreConfidence {
        guard hasSession else { return .calibrating }
        return hasStagedSleep ? .solid : .building
    }

    // MARK: - H9 stage low-confidence (restorative-share floor on a high-efficiency night)

    /// Restorative (deep+REM) share of asleep time below which staging is treated as LOW-CONFIDENCE on an
    /// otherwise high-efficiency night. A genuine well-structured adult night sits ~40–50% deep+REM; a near-
    /// zero restorative share on a night that ALSO scored high efficiency (lots of "asleep") is far more
    /// likely a staging miss (the EEG-free classifier's weakest link is light/deep/REM separation) than a
    /// real night with no deep or REM — so we flag the LOW CONFIDENCE rather than fake stages or tank Rest.
    /// ~10% is well below the healthy band yet above true edge cases. (#H9)
    public static let restorativeLowConfidenceShare: Double = 0.10

    /// Efficiency above which the restorative-share floor applies. A low-efficiency (fragmented) night
    /// legitimately carries less deep/REM, so the floor would false-positive there; we only flag the
    /// suspicious case — high efficiency (lots of measured sleep) but implausibly little restorative.
    public static let highEfficiencyThreshold: Double = 0.85

    /// Rest confidence WITH the H9 stage-quality check, the sparse-motion guard AND the hypnogram-coverage
    /// guard. Starts from `rest(hasSession:hasStagedSleep:)`, then DOWNGRADES a `.solid` tier to `.building`
    /// (low-confidence) when ANY of:
    ///  - the night was staged on SPARSE gravity (`gravitySparse`) — a WHOOP 4.0 synced/offload night banks
    ///    motion coarsely, too sparse to reliably stage sleep (#345), so a confident 85–100 Rest is unearned
    ///    however the engine filled the stages. This catches the case H9 MISSES: a sparse night whose staging
    ///    manufactures HIGH efficiency AND HIGH restorative reads SOLID under H9 alone (the #319 signature),
    ///    yet the underlying data can't support it; OR
    ///  - the night is high-efficiency yet its restorative (deep+REM) share is below
    ///    `restorativeLowConfidenceShare` — a likely staging miss (#H9); OR
    ///  - `stageCoverage` says the stage timeline accounts for less than `HypnogramCoverage.minCoverage` of
    ///    the span it claims. This is the case the other two structurally cannot see: a device-PROVIDED
    ///    hypnogram assembled from records that arrived incomplete has real stages over the part that DID
    ///    arrive, so its restorative share is ordinary and H9 stays quiet, while `gravitySparse` describes
    ///    the on-device motion stager and is false for a provided hypnogram (and inert for Oura outright,
    ///    which banks no gravity at all). Measured: a ring night covering 23% of its 601-minute span was
    ///    stored as 70 minutes of sleep and reported SOLID.
    /// `asleepSeconds`/`restorativeSeconds` are the night's totals; efficiency is asleep/in-bed in [0,1].
    /// `stageCoverage` is nil when coverage is unknown or not applicable — the guard fails OPEN there, so
    /// an unmeasurable payload keeps its previous tier rather than being downgraded on no evidence.
    /// `.calibrating`/`.building` from the base call are returned unchanged. Confidence-only — never changes
    /// the Rest score, invents stages, or claims the uncovered time was awake. Engine output only; the UI
    /// surfaces the tier later. (#H9, #345)
    public static func rest(hasSession: Bool, hasStagedSleep: Bool,
                            asleepSeconds: Double, restorativeSeconds: Double,
                            efficiency: Double, gravitySparse: Bool = false,
                            stageCoverage: Double? = nil) -> ScoreConfidence {
        let base = rest(hasSession: hasSession, hasStagedSleep: hasStagedSleep)
        if base != .solid { return base }
        if gravitySparse { return .building }   // #345: sparse-motion staging can't earn a SOLID Rest
        if let c = stageCoverage, c < HypnogramCoverage.minCoverage {
            return .building   // the timeline covers only part of the night it claims
        }
        if asleepSeconds <= 0 { return base }
        let restorativeShare = restorativeSeconds / asleepSeconds
        if efficiency >= highEfficiencyThreshold && restorativeShare < restorativeLowConfidenceShare {
            return .building   // high-efficiency night with near-zero deep+REM → low-confidence staging (#H9)
        }
        return base
    }
}
