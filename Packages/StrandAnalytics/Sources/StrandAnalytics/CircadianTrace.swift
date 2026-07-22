import Foundation

// CircadianTrace.swift - pure line formatters for the Circadian & Body Clock test mode.
//
// The circadian estimate is the app's most silently-failing derivation: it builds an hour-of-day activity
// profile, fits a cosinor, then applies three independent plausibility gates (days observed, relative
// amplitude, the CBT-before-wake and acrophase-after-CBT windows). Any one of them can drop the estimate,
// and the UI shows exactly the same thing for "not enough data" as for "the fit was rejected" - nothing.
// That is fine for a user and useless for anyone debugging it, which is what this mode exists to fix.
//
// Everything here is a PURE formatter over values the caller already has: no clock, no IO, no store, no
// PII (an hour-of-day profile and a fit, never raw samples or timestamps). One line per shape, tagged
// `.circadian` by the emitter, so the existing Test Centre log sink and export carry it with no new path.
public enum CircadianTrace {

    /// The INPUT to the fit: how many bins were built, from how many distinct days, and their coverage.
    /// The first thing to check when an estimate is missing - a fit can only be as good as this line.
    public static func inputLine(binCount: Int, daysObserved: Int, hoursCovered: Int,
                                 minDaysForFit: Int) -> String {
        "circadian input bins=\(binCount) days=\(daysObserved) hoursCovered=\(hoursCovered)/24 "
            + "minDays=\(minDaysForFit)"
    }

    /// The per-hour activity profile the cosinor was fitted to, as `hour:value` pairs. Bounded at 24
    /// entries by construction, so this cannot grow the log unexpectedly.
    public static func binsLine(_ bins: [CircadianEngine.ActivityBin]) -> String {
        let pairs = bins
            .map { String(format: "%.0f:%.1f", $0.hour, $0.activity) }
            .joined(separator: " ")
        return "circadian bins \(pairs)"
    }

    /// The fitted cosinor itself, plus the RELATIVE amplitude the plausibility gate actually tests
    /// (amplitude / mesor), stated next to the threshold it is compared against.
    public static func fitLine(_ fit: CircadianEngine.CosinorFit, minRelativeAmplitude: Double) -> String {
        let relative = fit.mesor != 0 ? fit.amplitude / abs(fit.mesor) : 0
        return String(format: "circadian fit mesor=%.2f amp=%.2f acrophase=%.2fh relAmp=%.3f minRelAmp=%.3f",
                      fit.mesor, fit.amplitude, fit.acrophaseHours, relative, minRelativeAmplitude)
    }

    /// The accepted estimate: the derived temperature minimum, the acrophase, the offset against the
    /// user's habitual wake, and the confidence the engine assigned with its own note.
    public static func phaseLine(_ estimate: CircadianEngine.PhaseEstimate, habitualWakeHour: Double) -> String {
        String(format: "circadian phase tempMin=%.2fh acrophase=%.2fh wake=%.2fh offset=%.0fmin "
               + "confidence=%@ note=%@",
               estimate.tempMinHour, estimate.acrophaseHours, habitualWakeHour,
               estimate.offsetVsScheduleMinutes, estimate.confidence.rawValue, estimate.note)
    }

    /// Why there is NO estimate at all. The whole point of the mode: a rejection has to be as visible as
    /// a result, and it has to name WHICH gate dropped it.
    public static func rejectedLine(reason: Reason, detail: String = "") -> String {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        return "circadian rejected reason=\(reason.rawValue)\(suffix)"
    }

    /// Why an estimate that DOES exist came back `unreadable` — the case that is genuinely impossible to
    /// tell apart from a good one on screen, since the surface shows the same soft "hard to read" line
    /// whether the run was too short or the rhythm too flat.
    public static func degradedLine(reasons: [Reason]) -> String {
        let list = reasons.isEmpty ? "none" : reasons.map(\.rawValue).joined(separator: ",")
        return "circadian degraded confidence=unreadable reasons=\(list)"
    }

    /// The gates that can drop or degrade a circadian estimate, as stable wire ids. Deliberately only the
    /// gates that actually exist in `CircadianEngine` — an advertised reason with no code behind it would
    /// send whoever reads the log looking for a gate that never fires.
    public enum Reason: String, Sendable, Equatable {
        /// Fewer usable HR buckets than the profile needs.
        case tooFewBuckets
        /// The hour-of-day profile has too few filled hours to fit.
        case tooFewBins
        /// The cosinor solve returned nothing.
        case noFit
        /// Fitted, but the rhythm is too flat to be believed (`minRelativeAmplitude`).
        case flatRhythm
        /// Fewer distinct days observed than `CircadianEngine.minDaysForFit`.
        case tooFewDays
    }
}
