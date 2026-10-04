import Foundation
import WhoopStore

// ChargeBaselines.swift — which nights the Charge baselines are folded from (#2525).
//
// Charge scores a night against personal baselines for HRV, resting HR, respiration and skin
// temperature. Before #2525 those baselines were folded from the WHOLE imported vendor history plus only
// the nights of the current scan window (21 by default). The wearer's own older nights dropped out on
// every pass while the import never did, so an import kept roughly a third of the weight for good, pinned
// to the wearer's state at the end of their subscription however old that was.
//
// The rule here is a correction of which nights count, not a new scoring method:
//   - Only nights inside a fixed calendar window (`windowDays`, counted back from the anchor day) count.
//     The window is the scan window's own 21 days, so a wearer with no import folds exactly the nights the
//     21-day pass always folded; what changes is that an imported night ages out like an own one, and
//     that a full-history repair pass folds the same 21 days instead of the whole history.
//   - The wearer's own (NOOP-computed) nights are the baseline. Imported vendor nights only SEED it: they
//     take part while the own nights alone would not yet make a trusted baseline (`handoffNights`, the
//     model's own `minNightsTrust`), and drop out entirely once they would. The two sources are different
//     algorithms, so they are never mixed past the cold start.
//   - The rule keeps no state. Every call decides from the nights it is given.
//
// Pure and database-free; the engine feeds it this pass's fresh values, the dashboard the stored rows.
// Byte-identical twin of the Kotlin `ChargeBaselines`.
public enum ChargeBaselines {

    /// Calendar days of nightly history a Charge baseline reads, counted back from the anchor day and
    /// including it. Deliberately the default scan window (`analyzeRecent(maxDays: 21)`), so the own nights
    /// a baseline reads are the ones the pass has just scored, and nothing changes for a wearer with no
    /// import.
    public static let windowDays: Int = 21

    /// One metric's nightly history for a Charge baseline, oldest first, ready for
    /// `Baselines.foldHistory(_:dayKeys:cfg:baselineEpoch:)`, plus the counts the diagnostic line reports.
    public struct History: Equatable, Sendable {
        /// `yyyy-MM-dd` keys, ascending, parallel to `values`.
        public let dayKeys: [String]
        /// The nightly values; nil is a night that exists but carried no value (skip-and-hold).
        public let values: [Double?]
        /// True while imported vendor nights still take part (the own nights are not yet trusted on
        /// their own and the window holds at least one imported night).
        public let seededByImport: Bool
        /// Valid own nights on or after the epoch inside the window: the count the handoff is decided on.
        public let ownValidNights: Int
        /// Imported nights this history carries (0 once the own nights have taken over).
        public let importedNights: Int

        public init(dayKeys: [String], values: [Double?], seededByImport: Bool,
                    ownValidNights: Int, importedNights: Int) {
            self.dayKeys = dayKeys
            self.values = values
            self.seededByImport = seededByImport
            self.ownValidNights = ownValidNights
            self.importedNights = importedNights
        }
    }

    /// Build one metric's Charge history from the imported and own nights (#2525).
    ///
    /// - Parameters:
    ///   - imported: imported vendor nights as `(day, value)`; a nil value is a night the import covers
    ///     without that metric. A repeated day keeps its last value.
    ///   - own: NOOP-computed nights, same shape. A repeated day keeps its last value.
    ///   - anchorDay: the `yyyy-MM-dd` day the window ends on (the scoring pass's local today).
    ///   - cfg: the metric's baseline configuration, used to count the valid own nights exactly as the
    ///     fold will.
    ///   - baselineEpoch: the epoch (seconds) the caller's fold will drop earlier nights by: the manual
    ///     recalibration epoch, or a later device-era cut. Own nights before it do not count toward the
    ///     handoff, because the fold will not use them.
    ///   - windowDays: see `windowDays`.
    ///   - handoffNights: valid own nights at which the imported nights stop taking part.
    ///
    /// Days are filtered with pure civil-day arithmetic (no time zone), keeping only days on or before the
    /// anchor and fewer than `windowDays` days before it. An unparseable key is dropped; an unparseable
    /// anchor yields an empty history, so a caller can only ever under-state a baseline, never read one
    /// from nights it cannot place. While seeding, an imported value wins a day both sources cover; an own
    /// night fills a day the import does not cover or covers without a value (the precedence of the
    /// dashboard's `mergeDaily` and of the engine merge before #2525, so a blank imported row can never
    /// shadow a night the strap measured). Kotlin twin: `ChargeBaselines.history`.
    public static func history(imported: [(day: String, value: Double?)],
                               own: [(day: String, value: Double?)],
                               anchorDay: String,
                               cfg: MetricCfg,
                               baselineEpoch: Double,
                               windowDays: Int = ChargeBaselines.windowDays,
                               handoffNights: Int = Baselines.minNightsTrust) -> History {
        let empty = History(dayKeys: [], values: [], seededByImport: false, ownValidNights: 0, importedNights: 0)
        guard windowDays > 0, let anchor = Baselines.isoEpochDay(anchorDay) else { return empty }
        let inWindow: (String) -> Bool = { day in
            guard let d = Baselines.isoEpochDay(day) else { return false }
            return d <= anchor && anchor - d < windowDays
        }

        var ownByDay: [String: Double?] = [:]
        for night in own where inWindow(night.day) { ownByDay[night.day] = night.value }
        let ownKeys = ownByDay.keys.sorted()
        let ownValues = ownKeys.map { ownByDay[$0]! }
        let ownValid = Baselines.foldHistory(ownValues, dayKeys: ownKeys, cfg: cfg,
                                             baselineEpoch: baselineEpoch).nValid

        var importedByDay: [String: Double?] = [:]
        for night in imported where inWindow(night.day) { importedByDay[night.day] = night.value }

        // Handed off, or nothing to seed with: the own nights are the whole history.
        if ownValid >= handoffNights || importedByDay.isEmpty {
            return History(dayKeys: ownKeys, values: ownValues, seededByImport: false,
                           ownValidNights: ownValid, importedNights: 0)
        }

        // Seeding: every imported night in the window, then the own nights on the days it leaves open. The
        // map's values are Optional, so `merged[day]` is `.some(nil)` for an imported night without a value:
        // that slot is open too, and the own night fills it. An own night without a value still registers
        // the day (a missing night), exactly as it would with no import.
        var merged = importedByDay
        for (day, value) in ownByDay {
            if let existing = merged[day], existing != nil { continue }   // an imported value wins
            merged[day] = value
        }
        let keys = merged.keys.sorted()
        return History(dayKeys: keys, values: keys.map { merged[$0]! }, seededByImport: true,
                       ownValidNights: ownValid, importedNights: importedByDay.count)
    }

    /// The Charge baselines the dashboard reads, resolved from the stored daily rows with the same rule the
    /// engine's pass-2 fold applies (#2525), so the "What shaped it" rows, the calibration count and the
    /// confidence tier describe the baseline the Charge headline was scored against.
    public struct Resolved: Equatable, Sendable {
        public let hrvHistory: History
        public let restingHRHistory: History
        public let respHistory: History
        public let hrv: BaselineState
        public let restingHR: BaselineState
        public let resp: BaselineState

        public init(hrvHistory: History, restingHRHistory: History, respHistory: History,
                    hrv: BaselineState, restingHR: BaselineState, resp: BaselineState) {
            self.hrvHistory = hrvHistory
            self.restingHRHistory = restingHRHistory
            self.respHistory = respHistory
            self.hrv = hrv
            self.restingHR = restingHR
            self.resp = resp
        }
    }

    /// Resolve HRV, resting-HR and respiration baselines from stored rows: `imported` are the imported
    /// vendor rows, `own` the NOOP-computed ("-noop") rows. HRV folds on `hrvEpoch`, resting HR and
    /// respiration on `recoveryEpoch`, exactly as the engine does. The engine additionally cuts respiration
    /// at a device-era boundary (#459), which needs a per-night source the stored rows do not carry; the
    /// two agree for every single-brand history. Kotlin twin: `ChargeBaselines.resolve`.
    public static func resolve(imported: [DailyMetric], own: [DailyMetric], anchorDay: String,
                               hrvEpoch: Double, recoveryEpoch: Double) -> Resolved {
        let hrvCfg = Baselines.hrvCfg, rhrCfg = Baselines.restingHRCfg, respCfg = Baselines.respCfg
        let hrvHistory = history(imported: imported.map { (day: $0.day, value: $0.avgHrv) },
                                 own: own.map { (day: $0.day, value: $0.avgHrv) },
                                 anchorDay: anchorDay, cfg: hrvCfg, baselineEpoch: hrvEpoch)
        let rhrHistory = history(imported: imported.map { (day: $0.day, value: $0.restingHr.map(Double.init)) },
                                 own: own.map { (day: $0.day, value: $0.restingHr.map(Double.init)) },
                                 anchorDay: anchorDay, cfg: rhrCfg, baselineEpoch: recoveryEpoch)
        let respHistory = history(imported: imported.map { (day: $0.day, value: $0.respRateBpm) },
                                  own: own.map { (day: $0.day, value: $0.respRateBpm) },
                                  anchorDay: anchorDay, cfg: respCfg, baselineEpoch: recoveryEpoch)
        return Resolved(
            hrvHistory: hrvHistory, restingHRHistory: rhrHistory, respHistory: respHistory,
            hrv: Baselines.foldHistory(hrvHistory.values, dayKeys: hrvHistory.dayKeys, cfg: hrvCfg,
                                       baselineEpoch: hrvEpoch),
            restingHR: Baselines.foldHistory(rhrHistory.values, dayKeys: rhrHistory.dayKeys, cfg: rhrCfg,
                                             baselineEpoch: recoveryEpoch),
            resp: Baselines.foldHistory(respHistory.values, dayKeys: respHistory.dayKeys, cfg: respCfg,
                                        baselineEpoch: recoveryEpoch))
    }

    /// The Recovery test-mode line naming what each Charge baseline was folded from this pass. Per metric,
    /// `own/N` means the own nights alone, N of them valid; `seed/N+M` means N valid own nights still seeded
    /// by M imported nights. It reports only the composition the engine decided, not why the wearer's values
    /// moved. Kotlin twin: `ChargeBaselines.logLine`, byte-identical.
    public static func logLine(anchorDay: String, hrv: History, restingHR: History, resp: History,
                               skin: History, windowDays: Int = ChargeBaselines.windowDays) -> String {
        let part: (History) -> String = { h in
            h.seededByImport ? "seed/\(h.ownValidNights)+\(h.importedNights)" : "own/\(h.ownValidNights)"
        }
        return "charge baseline anchor=\(anchorDay) window=\(windowDays)d hrv=\(part(hrv)) " +
            "rhr=\(part(restingHR)) resp=\(part(resp)) skin=\(part(skin))"
    }
}
