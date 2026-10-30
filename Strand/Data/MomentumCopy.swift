import Foundation
import StrandAnalytics
import WhoopStore

/// The recovery read Momentum leads most mornings with, as pure functions.
///
/// It used to be a cluster of private instance methods on `TodayView` (`synthesisCardStatus` /
/// `synthesisCardDetail` / `hrvInsightStatus` / `hrvInsightDetail` / `synthesisWord` /
/// `synthesisDetail`). By the time Momentum existed those had exactly ONE caller between them, so this
/// is a MOVE rather than a second copy — and it is what lets the Liquid Today screen show the same card
/// as the classic one instead of its own older one-liner. A second copy of these sentences on the other
/// screen is precisely the divergence this is meant to prevent.
///
/// Pure: no view, no store, no clock. Callers pass the rows they already hold, which is also what makes
/// the whole thing testable without a screen.
enum MomentumCopy {

    /// The ROW the card is talking about.
    ///
    /// This is the fix for a real defect: the headline used to be resolved from the carried
    /// last-scored day while the delta chip and the tone were resolved from the DISPLAYED day. On a
    /// carried read that meant a headline saying "HRV 64% over baseline" with no delta chip beside it,
    /// and a carried BAD recovery rendering in the neutral tone instead of the critical one. Everything
    /// the card says now comes from one row.
    static func subjectRow(displayed: DailyMetric?, lastScored: DailyMetric?) -> DailyMetric? {
        lastScored ?? displayed
    }

    /// The headline: the HRV-vs-baseline read when the baseline is established, else the state word.
    static func headline(row: DailyMetric?, hrvBaseline: BaselineState?) -> String {
        guard let pct = baselineDeltaPct(row: row, hrvBaseline: hrvBaseline) else {
            return stateWord(row?.recovery)
        }
        return pct >= 0
            ? String(localized: "HRV \(abs(pct))% over baseline")
            : String(localized: "HRV \(abs(pct))% under baseline")
    }

    /// The detail line. When the read is CARRIED from an earlier day it appends that day's provenance,
    /// so a prior read is never quietly passed off as today's.
    static func detail(row: DailyMetric?, hrvBaseline: BaselineState?, carriedCaption: String?) -> String {
        let body = detailBody(row: row, hrvBaseline: hrvBaseline)
        guard let carriedCaption, !carriedCaption.isEmpty else { return body }
        // The caption is a formatted date and frequently already ends in a period — an abbreviated
        // month ("Latest sleep · 15 Aug.") is the common case. Appending one unconditionally is what
        // produced the "Aug.." the card actually shipped with.
        let tail = carriedCaption.hasSuffix(".") ? carriedCaption : carriedCaption + "."
        return body + " " + tail
    }

    private static func detailBody(row: DailyMetric?, hrvBaseline: BaselineState?) -> String {
        guard let pct = baselineDeltaPct(row: row, hrvBaseline: hrvBaseline) else {
            return stateDetail(row)
        }
        let lead: String
        if pct >= 8 { lead = String(localized: "Your nervous system is well-recovered, so you're primed to push") }
        else if pct >= -8 { lead = String(localized: "You're in balance with your baseline, so moderate strain is well-judged") }
        else { lead = String(localized: "HRV is below your baseline, so ease into the day") }
        return lead + ". " + stateDetail(row)
    }

    /// The row's HRV as a whole percent above/below the learned baseline, or nil when there is not
    /// enough banked history for the comparison to be honest.
    ///
    /// `hrvBaseline` is `Repository.chargeBaselines?.hrv`: the baseline Charge scored against and the
    /// "What shaped it" rows describe. This used to average every loaded day's HRV itself, which kept
    /// the nights before a manual "Recalibrate baseline" and the imported history that Charge had
    /// already dropped, so a week after a reset the card still said "HRV 9% under baseline" while the
    /// breakdown below it read HRV as above baseline. One resolver now feeds both readouts.
    static func baselineDeltaPct(row: DailyMetric?, hrvBaseline: BaselineState?) -> Int? {
        guard let today = row?.avgHrv else { return nil }
        return hrvBaselineDeltaPct(today: today, baseline: hrvBaseline)
    }

    /// Pure core of the HRV-vs-baseline delta, rounded to a whole percent. nil until the baseline is
    /// usable (the same gate Charge scores on), the insight then falls back to the state word.
    ///
    /// STOPGAP (#696): NOOP mixes HRV measurement methods on the shared `avgHrv` field. Strap/WHOOP-CSV
    /// HRV is RMSSD (~20-100 ms) while Apple-Health-imported HRV is SDNN (~100-200 ms), so an SDNN
    /// reading compared against an RMSSD baseline yields a physiologically impossible delta. A real
    /// night-to-night HRV move never doubles or halves the value, so a reading outside [0.5x, 2x] of the
    /// baseline drops the comparison instead of rendering an alarming "X% over/under baseline" headline.
    /// Gated on the RATIO, not abs(pct): the percentage is bounded at -100% on the low side but unbounded
    /// high, so a symmetric threshold could not catch a near-zero reading.
    static func hrvBaselineDeltaPct(today: Double, baseline state: BaselineState?) -> Int? {
        guard today > 0, let state, state.usable else { return nil }
        let baseline = state.baseline
        guard baseline > 0 else { return nil }
        guard today <= 2.0 * baseline, today >= 0.5 * baseline else { return nil }
        return Int(((today - baseline) / baseline * 100).rounded())
    }

    /// The recovery-state word (#1405: a different axis from the ReadinessEngine training verdict, so
    /// they must not share a word — "Strong", never "Primed").
    static func stateWord(_ score: Double?) -> String {
        guard let s = score else { return String(localized: "No Data") }
        switch s {
        case ..<25:  return String(localized: "Depleted")
        case ..<50:  return String(localized: "Low")
        case ..<70:  return String(localized: "Steady")
        case ..<88:  return String(localized: "Strong")
        default:     return String(localized: "Peak")
        }
    }

    /// Plain-English synthesis of recovery + sleep. Whole-phrase variants per (charge band × sleep
    /// state), never a stitched tail fragment, so every combination is one clean catalog key.
    static func stateDetail(_ d: DailyMetric?) -> String {
        guard let d, let rec = d.recovery else {
            return String(localized: "No metrics yet. Import your Whoop export or wear the strap to begin.")
        }
        // true = slept 7h+; false = short; nil = no banked duration.
        let sleptWell: Bool? = d.totalSleepMin.map { $0 / 60.0 >= 7 }
        switch rec {
        case ..<50:
            switch sleptWell {
            case true?:  return String(localized: "Charge is low and sleep was consistent.")
            case false?: return String(localized: "Charge is low but sleep ran short.")
            case nil:    return String(localized: "Charge is low.")
            }
        case ..<70:
            switch sleptWell {
            case true?:  return String(localized: "Charge is steady and sleep was consistent.")
            case false?: return String(localized: "Charge is steady but sleep ran short.")
            case nil:    return String(localized: "Charge is steady.")
            }
        default:
            switch sleptWell {
            case true?:  return String(localized: "Charge is strong and sleep was consistent.")
            case false?: return String(localized: "Charge is strong but sleep ran short.")
            case nil:    return String(localized: "Charge is strong.")
            }
        }
    }

    /// The phase name `MenstrualCycleHomeCard`, both dashboards' cycle sections and Momentum use — one vocabulary for
    /// a phase, not a second guess at what to call each `CyclePhaseEngine.Phase`. Shared with the Android core.
    static func cyclePhaseTitle(_ phase: CyclePhaseEngine.Phase) -> String {
        switch phase {
        case .follicular:    return String(localized: "Follicular")
        case .periOvulatory: return String(localized: "Mid-cycle shift")
        case .luteal:        return String(localized: "Luteal")
        case .unknown:       return String(localized: "No clear pattern")
        case .learning:      return String(localized: "Learning your pattern")
        }
    }

    /// The phase's day range ("~day 12" or "~day 12-15"), nil without both ends.
    static func cycleDayRange(low: Int?, high: Int?) -> String? {
        guard let lo = low, let hi = high else { return nil }
        return lo == hi ? String(localized: "~day \(lo)") : String(localized: "~day \(lo)-\(hi)")
    }
}
