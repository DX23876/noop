import Foundation

// RecoveryForecast.swift — an evening estimate of TOMORROW-morning Charge.
//
// Pure, deterministic, DB-free. Given the recent Charge (recovery) history, the
// recent Effort (strain) history, today's Effort, and how much sleep is planned /
// banked tonight against the personal sleep need, this projects what tomorrow's
// Charge is LIKELY to wake at — with an honest ± error band.
//
// This is an ESTIMATE, not a measurement. WHOOP's morning recovery is computed from
// the NEXT night's HRV/RHR/respiration, none of which exist yet at the time this
// runs; so this can only lean on the levers that ARE known tonight. It is a simple,
// transparent weighting of three signed nudges around the recent Charge baseline —
// NOT a learned model — so it stays explainable and can be reasoned about line by line.
//
// Model (all adjustments are signed points ADDED to the baseline mean Charge):
//
//   center = mean(recent Charge over the last ~baselineWindow days)
//
//   1. Strain debt  — today's Effort vs the recent average Effort. A harder-than-
//      usual day suppresses tomorrow's Charge; an easier day lifts it a little.
//      adj₁ = −strainWeight × (todayEffort − meanEffort) / effortSpread     (clamped)
//
//   2. Sleep adequacy — planned/banked sleep tonight vs the personal sleep need.
//      Falling short of need suppresses Charge; meeting or beating it is neutral-to-
//      slightly-positive (sleeping far beyond need does not keep adding Charge).
//      adj₂ = sleepWeight × clamp(sleepHours/needHours − 1, −1, +0.25)
//
//   3. Mean reversion — if recent Charge has been trending, pull the projection a
//      little back toward the baseline rather than extrapolating the streak. A
//      sustained downswing is dampened, a sustained upswing is trimmed.
//      adj₃ = −reversionWeight × recentSlopePerDay
//
//   forecast = clamp(center + adj₁ + adj₂ + adj₃, 0, 100)
//
// Error band: the recent day-to-day SD of Charge, floored at minBandPoints and
// inflated when the baseline is thin (few nights) — a sparse history is less
// certain, and the ± says so honestly.
//
// Gating: returns nil unless there are at least minBaselineNights of recent Charge
// (so a cold-start user never sees a fabricated number). The UI shows the card only
// when this is non-nil.

// MARK: - Result

/// An evening projection of tomorrow-morning Charge (recovery, 0–100). APPROXIMATE.
public struct RecoveryForecast: Equatable, Sendable {
    /// The point estimate of tomorrow-morning Charge, 0–100 (rounded to a whole number).
    public let charge: Double
    /// Symmetric ± error band on `charge`, in Charge points (rounded to a whole number).
    public let band: Double
    /// Recent Charge baseline (mean) this projection is anchored to, 0–100.
    public let baseline: Double
    /// Planned/banked sleep hours tonight that the projection assumed.
    public let plannedSleepHours: Double
    /// Personal sleep need (hours) the adequacy term compared against.
    public let needHours: Double
    /// Nights of recent Charge history backing the baseline (drives confidence).
    public let nights: Int
    /// Per-score certainty tier (reuses the Charge/Effort/Rest confidence ladder).
    public let confidence: ScoreConfidence

    public init(charge: Double, band: Double, baseline: Double,
                plannedSleepHours: Double, needHours: Double,
                nights: Int, confidence: ScoreConfidence) {
        self.charge = charge
        self.band = band
        self.baseline = baseline
        self.plannedSleepHours = plannedSleepHours
        self.needHours = needHours
        self.nights = nights
        self.confidence = confidence
    }

    /// Low end of the band, clamped to [0, 100].
    public var low: Double { Swift.max(0, charge - band) }
    /// High end of the band, clamped to [0, 100].
    public var high: Double { Swift.min(100, charge + band) }
}

// MARK: - Engine

public enum RecoveryForecaster {

    // MARK: Tunables (documented, deterministic — NOT learned)

    /// Trailing Charge nights used for the baseline mean / SD / slope.
    public static let baselineWindow: Int = 14
    /// Minimum recent Charge nights before a forecast is offered (else nil — honest cold-start).
    public static let minBaselineNights: Int = 5
    /// Trailing Effort nights used for the strain-debt reference average.
    public static let effortWindow: Int = 14

    /// Charge points a one-spread excess of today's Effort over average removes.
    public static let strainWeight: Double = 9.0
    /// Effort spread (points) that defines "one unit" of strain excess. A day this far
    /// above your average Effort costs the full `strainWeight`. Deliberately a fixed,
    /// explainable spread (not a personal SD) so the nudge is stable and legible.
    public static let effortSpread: Double = 12.0
    /// Max |strain-debt| nudge (points), so one freak max-Effort day can't dominate.
    public static let strainAdjCap: Double = 12.0

    /// Charge points a full night short / over of sleep-need moves the estimate.
    public static let sleepWeight: Double = 14.0
    /// Sleep beyond need keeps helping only up to this fraction (diminishing returns).
    public static let sleepOverCap: Double = 0.25

    /// Charge points removed per point/day of recent up-slope (and added back per
    /// point/day of down-slope) — the mean-reversion damping.
    public static let reversionWeight: Double = 1.0
    /// Max |mean-reversion| nudge (points).
    public static let reversionAdjCap: Double = 8.0

    /// Floor on the ± band (points) — even a steady sleeper isn't perfectly predictable.
    public static let minBandPoints: Double = 8.0
    /// Extra ± points added while the baseline is below `trustedNights` (thin history).
    public static let thinBandPoints: Double = 6.0
    /// Recent Charge nights at/above which the band is no longer inflated for thinness.
    public static let trustedNights: Int = 10
    /// Nights informing the personal sleep need at/above which the need is "solid"
    /// (matches the Charge/Effort/Rest building-vs-solid threshold of 7).
    public static let solidNeedNights: Int = 7

    /// Default personal sleep need (hours) when the caller has none to refine it.
    public static let defaultNeedHours: Double = AnalyticsEngine.Rest.defaultNeedHours

    // MARK: - Forecast

    /// Project tomorrow-morning Charge from tonight's known levers. APPROXIMATE; nil
    /// until there are at least `minBaselineNights` of recent Charge to anchor to.
    ///
    /// - Parameters:
    ///   - recentCharge: recent daily Charge values, OLDEST→NEWEST (0–100). Only the
    ///     trailing `baselineWindow` are used for the baseline mean/SD/slope.
    ///   - recentEffort: recent daily Effort values, OLDEST→NEWEST (0–100); the
    ///     trailing `effortWindow` set the strain-debt reference average. May be
    ///     empty — the strain term then drops.
    ///   - todayEffort: today's Effort (0–100), or nil to drop the strain term.
    ///   - plannedSleepHours: sleep hours planned / already banked tonight. Negative
    ///     is treated as 0.
    ///   - needHours: personal sleep need (hours); nil → `defaultNeedHours`.
    ///   - needNights: recent nights that informed `needHours` (0 = still the default);
    ///     drives the Rest-style confidence tier.
    public static func forecast(recentCharge: [Double],
                                recentEffort: [Double] = [],
                                todayEffort: Double?,
                                plannedSleepHours: Double,
                                needHours: Double? = nil,
                                needNights: Int = 0) -> RecoveryForecast? {
        let chargeWindow = Array(recentCharge.suffix(baselineWindow))
        let nights = chargeWindow.count
        guard nights >= minBaselineNights else { return nil }

        let center = mean(chargeWindow)
        let sd = sampleSD(chargeWindow)
        let slope = leastSquaresSlope(chargeWindow)

        // 1. Strain debt: today vs the recent average Effort (both 0–100).
        var strainAdj = 0.0
        if let today = todayEffort, !recentEffort.isEmpty {
            let meanEffort = mean(Array(recentEffort.suffix(effortWindow)))
            let excess = (today - meanEffort) / effortSpread
            strainAdj = clamp(-strainWeight * excess, -strainAdjCap, strainAdjCap)
        }

        // 2. Sleep adequacy: planned sleep vs personal need.
        let need = Swift.max(needHours ?? defaultNeedHours, 0.1)
        let sleep = Swift.max(plannedSleepHours, 0.0)
        let sleepRatio = clamp(sleep / need - 1.0, -1.0, sleepOverCap)
        let sleepAdj = sleepWeight * sleepRatio

        // 3. Mean reversion: dampen a recent streak back toward the baseline.
        let reversionAdj = clamp(-reversionWeight * slope, -reversionAdjCap, reversionAdjCap)

        let raw = center + strainAdj + sleepAdj + reversionAdj
        let charge = (clamp(raw, 0.0, 100.0)).rounded()

        // ± band: recent SD, floored, inflated while the baseline is thin.
        var band = Swift.max(sd, minBandPoints)
        if nights < trustedNights { band += thinBandPoints }
        band = band.rounded()

        // Confidence rides the SAME calibrating/building/solid ladder as the daily
        // scores. The forecast always clears `minBaselineNights` to reach here (so it
        // is never .calibrating), then it is .building on a thin baseline OR an
        // unrefined sleep-need default, and .solid only when both the baseline is full
        // (≥ trustedNights) and the personal need is informed.
        let confidence: ScoreConfidence =
            (nights >= trustedNights && needNights >= solidNeedNights) ? .solid : .building

        return RecoveryForecast(charge: charge, band: band, baseline: center,
                                plannedSleepHours: sleep, needHours: need,
                                nights: nights, confidence: confidence)
    }

    // MARK: - Stats (self-contained so the Kotlin mirror is line-for-line)

    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation (ddof = 1); 0 for fewer than 2 values.
    static func sampleSD(_ values: [Double]) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        let m = mean(values)
        var ss = 0.0
        for v in values { let d = v - m; ss += d * d }
        return (ss / Double(n - 1)).squareRoot()
    }

    /// OLS slope of value vs the 0-based index (per-day trend); 0 for < 2 points.
    static func leastSquaresSlope(_ values: [Double]) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        let meanX = Double(n - 1) / 2.0
        let meanY = mean(values)
        var num = 0.0, den = 0.0
        for (i, v) in values.enumerated() {
            let dx = Double(i) - meanX
            num += dx * (v - meanY)
            den += dx * dx
        }
        return den == 0 ? 0 : num / den
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        // Inclusive-bound equality is already in range: return x itself so Swift
        // and Kotlin preserve the same IEEE signed-zero bit (#56).
        if x < lo { return lo }
        if x > hi { return hi }
        return x
    }
}
