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
    static func headline(row: DailyMetric?, allDays: [DailyMetric], fallbackDayKey: String) -> String {
        guard let pct = baselineDeltaPct(row: row, allDays: allDays, fallbackDayKey: fallbackDayKey) else {
            return stateWord(row?.recovery)
        }
        return pct >= 0
            ? String(localized: "HRV \(abs(pct))% over baseline")
            : String(localized: "HRV \(abs(pct))% under baseline")
    }

    /// The detail line. When the read is CARRIED from an earlier day it appends that day's provenance,
    /// so a prior read is never quietly passed off as today's.
    static func detail(row: DailyMetric?, allDays: [DailyMetric], fallbackDayKey: String,
                       carriedCaption: String?) -> String {
        let body = detailBody(row: row, allDays: allDays, fallbackDayKey: fallbackDayKey)
        guard let carriedCaption, !carriedCaption.isEmpty else { return body }
        // The caption is a formatted date and frequently already ends in a period — an abbreviated
        // month ("Latest sleep · 15 Aug.") is the common case. Appending one unconditionally is what
        // produced the "Aug.." the card actually shipped with.
        let tail = carriedCaption.hasSuffix(".") ? carriedCaption : carriedCaption + "."
        return body + " " + tail
    }

    private static func detailBody(row: DailyMetric?, allDays: [DailyMetric],
                                   fallbackDayKey: String) -> String {
        guard let pct = baselineDeltaPct(row: row, allDays: allDays, fallbackDayKey: fallbackDayKey) else {
            return stateDetail(row)
        }
        let lead: String
        if pct >= 8 { lead = String(localized: "Your nervous system is well-recovered, so you're primed to push") }
        else if pct >= -8 { lead = String(localized: "You're in balance with your baseline, so moderate strain is well-judged") }
        else { lead = String(localized: "HRV is below your baseline, so ease into the day") }
        return lead + ". " + stateDetail(row)
    }

    /// The row's HRV as a whole percent above/below the learned baseline, or nil when there is not
    /// enough banked history for the comparison to be honest. Excludes the row's OWN day so a carried
    /// read is not compared against a baseline that contains it (#543).
    static func baselineDeltaPct(row: DailyMetric?, allDays: [DailyMetric],
                                 fallbackDayKey: String) -> Int? {
        guard let today = row?.avgHrv, today > 0 else { return nil }
        let excludeDay = row?.day ?? fallbackDayKey
        let prior = allDays
            .filter { $0.day != excludeDay }
            .compactMap(\.avgHrv)
            .filter { $0 > 0 }
        return TodayView.hrvBaselineDeltaPct(today: today, priorHrvs: prior)
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
}
