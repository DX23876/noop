import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Charge display state (pure, testable)
//
// The ONE rule for what the Charge hero may say on a given day, shared by every screen that draws
// one: classic `TodayView`, `LiquidTodayView`, the two dashboards (`TrendsDashboardView` /
// `OverviewDashboardView`) and the Heute prototype. It lived nested in `LiquidTodayView` while only
// that screen used it; a fifth caller is well past the point where a dashboard should have to reach
// through another screen's namespace to ask what today's Charge is.
//
// Moving it changed no behaviour: the truth table, the copy and the catalog keys below are the ones
// `LiquidChargeCarryTests` already pinned, verbatim.

/// What the Charge hero can honestly say for the selected day. Pure + static so the truth table is
/// testable with no clock and no view (`ChargeDisplayTests` / `LiquidChargeCarryTests`).
///
/// See `LiquidChargeCarryTests` for the regression this closes: Liquid read `displayDay?.recovery`
/// raw, so after the 04:00 rollover — or on any day with no scored night — Charge blanked while the
/// Rest hero (`freshRestScore`) and the vitals (`Repository.lastVitalsDay`) carried right beside it,
/// and the widget/watch/Live Activity (`Repository.widgetAnchor`, #911) all showed a number. The two
/// dashboards drew their Charge hero the same raw way until they were routed through here.
///
/// The SELECTION is not re-implemented here: callers pass the row `TodayView.lastScoredRecoveryDay`
/// picked (its #547 future-day guard included) and the caption comes from `TodayView.carriedCaption`,
/// so no two screens drawing a Charge can drift apart.
enum ChargeDisplay: Equatable {
    /// The selected day scored its own Charge.
    case scored(pct: Double)
    /// No score for the selected day; showing a REAL prior night's, stamped with whose it is.
    case carried(pct: Double, caption: String)
    /// Pre-seed-gate: the baseline is still learning and owns its own "N of 4 nights" copy.
    case calibrating(nights: Int)
    /// Nothing honest to show — no score, no prior night, and not calibrating.
    case noData

    /// The number the hero vessel draws, or nil for the honest empty state. A carry draws the REAL
    /// prior value; the empty states draw nothing rather than a fabricated zero.
    var pct: Double? {
        switch self {
        case .scored(let p): return p
        case .carried(let p, _): return p
        case .calibrating, .noData: return nil
        }
    }

    /// The short Charge-state pill beside the greeting. It shares a row with the greeting under a
    /// `fixedSize`, so it stays SHORT — the carried day's full "Last night · <date>" stamp lives in
    /// `caption`, not here. Only `.calibrating` may say "Calibrating": the pill used to key off
    /// `recovery != nil` and so claimed a calibrating baseline on every unscored day, including a
    /// trusted wearer who simply hadn't worn the strap that night.
    var stateLabel: String {
        switch self {
        case .scored: return String(localized: "Solid")
        case .carried: return String(localized: "Last night")
        case .calibrating: return String(localized: "Calibrating")
        case .noData: return String(localized: "No data")
        }
    }

    /// The carried night's provenance stamp ("Last night · 2 Sep", or "Latest sleep · …" once it is older
    /// than `TodayView.carryFreshnessDays`), or nil when the displayed number is the selected day's own.
    /// A screen that draws `pct` MUST show this whenever it is non-nil: without it a carried score is
    /// passed off as today's, which is the one thing the carry is not allowed to do.
    var carriedCaption: String? {
        guard case .carried(_, let caption) = self else { return nil }
        return caption
    }

    /// The two lines an EMPTY Charge ring draws instead of a bare "—". Classic Today's `ringEmptyOverlay`
    /// copy verbatim (same catalog keys), so a calibrating wearer reads the same "Calibrating / N of 4"
    /// wherever the ring is drawn. nil for the states that draw a number, and for `.noData` — which has
    /// nothing to say beyond the dash.
    var emptyRingLines: (title: String, subtitle: String)? {
        guard case .calibrating(let nights) = self else { return nil }
        return (String(localized: "Calibrating"), String(localized: "\(nights) of \(Baselines.minNightsSeed)"))
    }

    /// The synthesis-card detail line while the baseline is still forming — the same "N of
    /// `Baselines.minNightsSeed` nights" progress classic `TodayView.calibrationDetail` surfaces, so a
    /// wearer in their first few nights reads identical calibration copy on both Today screens (before
    /// this, Liquid dropped the count and showed a bare "Calibrating"). Non-nil ONLY for `.calibrating`:
    /// the compact greeting pill stays short ("Calibrating") because it shares a `fixedSize` row with
    /// the greeting, so the count lives here in the card, exactly as classic keeps it out of its
    /// `ScoreStatePill`. Reuses classic's String Catalog key verbatim — one entry serves both screens.
    var calibrationDetail: String? {
        guard case .calibrating(let nights) = self else { return nil }
        return String(localized: "Learning your baseline, \(nights) of \(Baselines.minNightsSeed) nights.")
    }

    static func resolve(todayRecovery: Double?, priorScored: DailyMetric?,
                        calibrationNights: Int?, todayKey: String) -> ChargeDisplay {
        if let pct = todayRecovery { return .scored(pct: pct) }
        // Calibration owns its own copy and beats the carry — mid-calibration there is no trustworthy
        // prior score to stand in. Mirrors `lastScoredRecoveryDay`, which returns nil when calibrating.
        if let n = calibrationNights { return .calibrating(nights: n) }
        // `lastScoredRecoveryDay` only ever selects a row whose recovery is non-nil, so the second bind
        // is belt-and-suspenders: a nil falls through to noData rather than fabricating a carry.
        guard let prior = priorScored, let pct = prior.recovery else { return .noData }
        return .carried(pct: pct,
                        caption: TodayView.carriedCaption(priorDayKey: prior.day, todayKey: todayKey))
    }

    /// The WHOLE composition in one call — calibration count, then the carried row, then the state —
    /// for a screen that needs nothing from the intermediate steps.
    ///
    /// `LiquidTodayView` deliberately keeps the three-step form: it also anchors Readiness and the
    /// Charge-breakdown sheet on `priorScored` and reads the calibration count for its own copy, so it
    /// holds those values anyway. A dashboard wants only the answer, and had been writing
    /// `displayDay?.recovery` instead — the shortest possible wrong version of this. Composing it here
    /// means a caller cannot order the three steps differently from the two Today screens.
    ///
    /// `days` is the full oldest→newest history, `displayDay` the row on screen, `selectedDayKey` the
    /// screen's own day key, `isToday` whether offset 0 is selected. A navigated past day never
    /// calibrates and never carries, so it resolves to its own row or `.noData`, exactly as classic
    /// Today does.
    static func resolve(days: [DailyMetric], displayDay: DailyMetric?,
                        selectedDayKey: String, isToday: Bool) -> ChargeDisplay {
        // The SAME `RecoveryScorer` helper `TodayView.computeCalibration` and Liquid's load() read, so
        // the screens agree on when a wearer is genuinely mid-calibration rather than simply lacking a
        // scored night.
        let calNights = isToday
            ? RecoveryScorer.calibrationNights(nightlyHrv: days.map(\.avgHrv),
                                               dayKeys: days.map(\.day),
                                               hasRecovery: displayDay?.recovery != nil)
            : nil
        // Liquid's `tkey`: today's OWN banked key when there is a row, so neither the selection bound
        // nor the caption's recency anchor can echo the still-forming row or drift past it (#304).
        let tkey = displayDay?.day ?? selectedDayKey
        let priorScored = TodayView.lastScoredRecoveryDay(days: days,
                                                          selectedDayKey: tkey,
                                                          isToday: isToday,
                                                          todayScored: displayDay?.recovery != nil,
                                                          isCalibrating: calNights != nil)
        return resolve(todayRecovery: displayDay?.recovery, priorScored: priorScored,
                       calibrationNights: calNights, todayKey: tkey)
    }
}
