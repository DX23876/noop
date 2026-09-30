import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Charge breakdown wiring (pure, testable)
//
// The fold-and-score wiring behind the "What shaped it" sheet, lifted out of the two views that had
// byte-identical private copies of it (TodayView.chargeBreakdown / CoupledView.chargeBreakdown). They
// differed only in which row they display and where their sleep-performance number comes from, both of
// which are inputs, so one function serves both.
//
// Extracted so it can be TESTED. Living inside a `View` struct as a private method meant the only way to
// exercise it was to render the view, so the iOS side of this path had no test at all while the Android
// twin did. Kotlin twin: `TodayScoring.recoveryChargeDrivers`.
//
// Pure: no SwiftUI state, no I/O, no store access. Nothing here invents a number. The drivers come from
// `RecoveryScorer.chargeDrivers` and the tier is SURFACED from `ScoreConfidence.charge` against the same
// HRV baseline the drivers scored with, so the header and the rows agree by construction. The baselines
// themselves are resolved once per refresh by `Repository.chargeBaselines` (#2525).
enum ChargeBreakdownWiring {

    /// The ordered Charge driver rows for `row` plus its confidence tier, scored against `baselines`, or nil
    /// when the night cannot honestly score (missing HRV or resting HR, or an HRV baseline that is not yet
    /// usable) so the sheet hides rather than showing fabricated rows.
    ///
    /// `baselines` is `Repository.chargeBaselines`: the baselines resolved with the engine's own rule
    /// (#2525), so these rows and the tier describe the baseline the Charge headline was scored against.
    /// Before #2525 this folded the whole visible history itself, which kept every imported night and every
    /// stored own night while the headline kept only the recent own nights plus the import; the page could
    /// show one baseline in the rows and score against another. (#2315 had already closed the same gap for
    /// the recalibration epoch; the resolver now applies both epochs.)
    ///
    /// `sleepPerfPercent` is the Rest composite on a 0-100 scale, divided by 100 here to match
    /// `AnalyticsEngine`'s `sleepPerf` form, so the Sleep row scores against the headline's own input.
    ///
    /// The resting-HR and respiration baselines are passed only when usable. `RecoveryScorer` and
    /// `chargeDrivers` both apply that gate themselves since #1990, so these are belt-and-braces rather
    /// than load-bearing; they are kept because they say the intent at the call site, which is where a
    /// reader looks first.
    static func breakdown(baselines: ChargeBaselines.Resolved,
                          row: DailyMetric,
                          sleepPerfPercent: Double?) -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        guard let hrv = row.avgHrv, let rhr = row.restingHr else { return nil }
        let hrvBase = baselines.hrv
        guard hrvBase.usable else { return nil }
        let rhrBase = baselines.restingHR
        let respBase = baselines.resp
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
            hrvBaseline: hrvBase,
            rhrBaseline: rhrBase.usable ? rhrBase : nil,
            respBaseline: respBase.usable ? respBase : nil,
            sleepPerf: sleepPerfPercent.map { $0 / 100.0 },
            skinTempDev: row.skinTempDevC)
        return (drivers, ScoreConfidence.charge(recovery: row.recovery, hrvBaseline: hrvBase))
    }
}
