import Foundation
import StrandCore

// MARK: - Copy

/// String building for the progress card, kept out of the view so the wording is unit-tested and the
/// rounding rules live in one place.
enum AnalysisProgressFormat {

    /// A coarse duration: seconds below a minute (rounded UP to 5 s so the number does not flicker every
    /// tick), whole minutes above it. Rounding up rather than to-nearest is deliberate — an estimate that
    /// habitually finishes early reads as reliable; one that overruns reads as broken.
    static func coarseDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 {
            let step = max(5, (Int(s.rounded(.up)) + 4) / 5 * 5)
            return String(localized: "\(step) s")
        }
        let minutes = Int((s / 60).rounded(.up))
        return String(localized: "\(minutes) min")
    }

    /// The line under the bar: which day, and either the estimate or an honest reason there isn't one.
    static func detailLine(_ p: AnalysisProgress, now: Date) -> String {
        switch p.stage {
        case .preparing:
            return String(localized: "Reading history and folding baselines…")
        case .finishing:
            guard p.reusedDays > 0 else { return String(localized: "Saving scores…") }
            // Stated at the end too: this is the line a wearer reads when they finally look, and
            // "re-derived 2 of 21" is the difference between a working pass and the runaway one this
            // replaced. `totalDays` rather than `completedDays` — every day is behind it by now.
            return String(format: String(localized: "Saving scores — re-derived %lld of %lld days"),
                          locale: AppLanguage.activeLocale,
                          Int64(max(0, p.totalDays - p.reusedDays)), Int64(p.totalDays))
        case .scanning:
            let position = String(
                format: String(localized: "Day %lld of %lld"),
                locale: AppLanguage.activeLocale,
                Int64(p.completedDays + 1), Int64(p.totalDays))
            // The reuse count comes FIRST when there is one. It is the answer to the question the
            // counter provokes ("is it redoing everything again?"), and it is the honest headline: on a
            // settled library almost every day here is a fingerprint match, not a re-score.
            let reuse = p.reusedDays > 0
                ? String(format: String(localized: "%lld unchanged"),
                         locale: AppLanguage.activeLocale, Int64(p.reusedDays))
                : nil
            let head = reuse.map {
                String(format: String(localized: "%@ · %@"), locale: AppLanguage.activeLocale,
                       position, $0)
            } ?? position
            guard let eta = p.estimatedSecondsRemaining(now: now) else {
                return String(format: String(localized: "%@ · estimating…"),
                              locale: AppLanguage.activeLocale, head)
            }
            return String(format: String(localized: "%@ · about %@ left"),
                          locale: AppLanguage.activeLocale, head, coarseDuration(eta))
        }
    }

    /// The freshness line. Says what was observed — when the last step landed — and nothing more. Once
    /// the gap passes `stallSeconds` the wording changes to name the gap rather than to declare a hang:
    /// the pass may be inside one slow day, and this line cannot tell the difference.
    static func freshnessLine(_ p: AnalysisProgress, now: Date) -> String {
        let gap = p.secondsSinceLastStep(now: now)
        if p.looksStalled(now: now) {
            return String(format: String(localized: "No progress for %@"),
                          locale: AppLanguage.activeLocale, coarseDuration(gap))
        }
        return String(format: String(localized: "Last step %@ ago"),
                      locale: AppLanguage.activeLocale, coarseDuration(gap))
    }
}
