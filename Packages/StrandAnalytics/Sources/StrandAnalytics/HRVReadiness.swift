import Foundation

// HRVReadiness.swift — OPT-IN experimental "HRV readiness (Plews/Altini)" tier readout.
//
// The Kotlin twin is android/.../analytics/HRVReadiness.kt. Cross-platform parity is the contract: every
// constant, gate, and formula here must stay byte-identical to that source.
//
// This is a PURE, deterministic, DB-free engine and it does NOT change the default Charge/ring in any way
// — it is only surfaced (read-only) behind the PuffinExperiment `noopHrvReadiness` flag (off by default)
// and feeds NO downstream gate. It reimplements the endurance-science "smallest worthwhile change" (SWC)
// reading of nightly HRV popularised by Plews et al. and Marco Altini: work in the LOG domain (ln RMSSD is
// closer to normal and stabilises variance), compare a short 7-night rolling baseline against a longer
// personal normal band (±0.5 SD), and read the tier off where the short baseline sits relative to that
// band. A single bad night barely moves the 7-night baseline, so the reading is far more robust than a raw
// single-night z.
//
// INPUT: the SAME nightly RMSSD series RecoveryScorer / ReadinessEngine consume — DailyMetric.avgHrv[] in
// ms, oldest -> newest (nils allowed for missing nights). Physiologically implausible nights are dropped
// through the shared Baselines.hrvCfg bounds (5..250 ms) so one decode glitch can't skew it.
//
// OUTPUT (HRVReadinessResult): the tier (primed / normal / suppressed), the 7-night baseline and the
// personal normal band (all back in ms via exp), and an informational overreaching-watch flag. Returns nil
// (the honest ".calibrating" edge) below `minNights` valid nights: never a fabricated number. Mirrors the
// WatchRecovery nil+.calibrating honesty pattern.
//
// This is a rough / early experiment: it is NOT yet validated against varying real data (n=1). Outputs are
// APPROXIMATE wellness estimates, not medical advice.

/// Where tonight's 7-night HRV baseline sits vs the personal normal band. Mirrors Kotlin `ReadinessTier`.
public enum ReadinessTier: String, Equatable, Sendable {
    case primed
    case normal
    case suppressed
}

/// Result of an `HRVReadiness.evaluate` pass. All `*Ms` fields are back in milliseconds (exp of the log
/// domain the engine works in). Mirrors Kotlin `HRVReadinessResult`.
public struct HRVReadinessResult: Equatable, Sendable {
    /// Tier from the SWC comparison of the 7-night baseline against the personal normal band.
    public let tier: ReadinessTier
    /// 7-night rolling HRV baseline (ms) = exp(mean of ln RMSSD over the trailing rollWindow nights).
    public let baseline7Ms: Double
    /// Lower edge of the personal normal band (ms) = exp(longMean − 0.5·longSD).
    public let normalLowMs: Double
    /// Upper edge of the personal normal band (ms) = exp(longMean + 0.5·longSD).
    public let normalHighMs: Double
    /// Informational only (does NOT change the tier): a sustained falling CV trend while the 7-night
    /// baseline sits below the long mean — the classic parasympathetic-overreaching signature.
    public let overreachingWatch: Bool

    public init(tier: ReadinessTier, baseline7Ms: Double, normalLowMs: Double, normalHighMs: Double,
                overreachingWatch: Bool) {
        self.tier = tier
        self.baseline7Ms = baseline7Ms
        self.normalLowMs = normalLowMs
        self.normalHighMs = normalHighMs
        self.overreachingWatch = overreachingWatch
    }
}

/// OPT-IN experimental HRV-readiness (Plews/Altini SWC) engine. Mirrors Kotlin `HRVReadiness`.
public enum HRVReadiness {

    // MARK: - Constants (name them; mirror Kotlin exactly)

    /// Short rolling baseline window (nights) — the Plews/Altini 7-night HRV baseline.
    public static let rollWindow: Int = 7
    /// Long personal-normal window (nights) when enough valid nights exist.
    public static let longWindow: Int = 60
    /// Long-window fallback (nights) when fewer than `longWindow` valid nights are banked.
    public static let longWindowFallback: Int = 30
    /// Smallest-worthwhile-change half-width factor: the normal band is longMean ± swcK·longSD.
    public static let swcK: Double = 0.5
    /// Minimum VALID nights before a reading is offered (else nil + the honest calibrating edge). Its OWN
    /// constant — deliberately NOT aliased to `WatchRecovery.minBaselineNights`: the SWC band needs a longer
    /// warm-up than the watch-recovery gate. It only mirrors WatchRecovery's nil+.calibrating HONESTY
    /// pattern, not its value.
    public static let minNights: Int = 14
    /// Trailing nights over which the CV trend (overreaching watch) is fit.
    public static let cvTrendWindow: Int = 28
    /// Floor on the long-window SD so a flat history yields a deterministic, tiny non-degenerate normal band
    /// instead of an ULP-fragile zero-width one (baseline7 and longMean are both the mean of the same
    /// constant here, but can differ by a float ULP, which a zero-width band would flip to primed/suppressed).
    public static let longSDFloor: Double = 1e-9

    // MARK: - Evaluate

    /// Compute the Plews/Altini HRV-readiness reading. Returns nil (calibrating) below `minNights` valid
    /// nights — never a fabricated value.
    ///
    /// - Parameter avgHrv: nightly RMSSD (ms), oldest -> newest; nils = missing nights. Out-of-range nights
    ///   (outside `Baselines.hrvCfg` 5..250 ms) are dropped as decode artefacts.
    public static func evaluate(avgHrv: [Double?]) -> HRVReadinessResult? {
        let cfg = Baselines.hrvCfg
        // Drop nils + physiologically implausible nights (shared bounds), keep order oldest -> newest.
        let valid = avgHrv.compactMap { v -> Double? in
            guard let v = v, cfg.minVal <= v && v <= cfg.maxVal else { return nil }
            return v
        }
        // Honesty gate: below minNights valid nights we refuse to score (calibrating). Never fabricate.
        guard valid.count >= minNights else { return nil }

        // Log domain: ln RMSSD (Plews/Altini). max(.,1.0) guards ln of a sub-1 value; bounds already keep it >=5.
        let ell = valid.map { log(max($0, 1.0)) }

        // 7-night rolling baseline (the short, robust HRV baseline).
        let baseline7 = RecoveryForecaster.mean(Array(ell.suffix(rollWindow)))

        // Long personal-normal window: longWindow if we have that many valid nights, else the 30-night fallback.
        let longWin = valid.count >= longWindow ? longWindow : longWindowFallback
        let longEll = Array(ell.suffix(longWin))
        let longMean = RecoveryForecaster.mean(longEll)
        // SD over the long window; if fewer than 2 long nights, fall back to the 7-night SD; floored so a
        // flat history gives a deterministic tiny band rather than an ULP-fragile zero-width one.
        let longSDraw = longEll.count >= 2 ? RecoveryForecaster.sampleSD(longEll)
                                           : RecoveryForecaster.sampleSD(Array(ell.suffix(rollWindow)))
        let longSD = max(longSDraw, longSDFloor)

        // Smallest-worthwhile-change band (±0.5 SD in the log domain).
        let swcHalf = swcK * longSD
        let normalLow = longMean - swcHalf
        let normalHigh = longMean + swcHalf

        // Tier: above the band -> primed; inside (inclusive of the low edge) -> normal; below -> suppressed.
        let tier: ReadinessTier
        if baseline7 > normalHigh {
            tier = .primed
        } else if baseline7 >= normalLow {
            tier = .normal
        } else {
            tier = .suppressed
        }

        // Overreaching watch (INFORMATIONAL — never changes the tier): a sustained FALLING coefficient-of-
        // variation trend while the 7-night baseline sits below the long mean (parasympathetic overreach).
        // Build a rolling CV series (one point per night with a full trailing-7 window) over the last
        // cvTrendWindow nights, then OLS its slope.
        var cvSeries: [Double] = []
        let cvStart = max(rollWindow - 1, ell.count - cvTrendWindow)
        var i = cvStart
        while i < ell.count {
            let w = Array(ell[(i - rollWindow + 1)...i])
            let m = RecoveryForecaster.mean(w)
            let cv = m != 0.0 ? 100.0 * RecoveryForecaster.sampleSD(w) / m : 0.0
            cvSeries.append(cv)
            i += 1
        }
        let cvSlope = RecoveryForecaster.leastSquaresSlope(cvSeries)
        let overreachingWatch = cvSlope < 0.0 && baseline7 < longMean

        return HRVReadinessResult(tier: tier,
                                  baseline7Ms: exp(baseline7),
                                  normalLowMs: exp(normalLow),
                                  normalHighMs: exp(normalHigh),
                                  overreachingWatch: overreachingWatch)
    }
}
