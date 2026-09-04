import Foundation

// MARK: - Analysis pass progress (pure, testable)
//
// "Analyse & Wartung" used to show a bare spinner while `analyzeRecent` ran. A spinner says only that
// the engine BELIEVES it is working — it looks exactly the same for a pass that is chewing through day
// 7 of 21 and for one that stopped returning half an hour ago. Both buttons in that card are disabled
// on the same flag (`engine.computing`), so a pass that never finishes locks the one control that could
// clear it, with nothing on screen to tell the two states apart.
//
// The two questions a person actually has are "is it moving?" and "how much longer?", and they need
// different evidence:
//
//  • MOVING is observed directly. The scan publishes a step per day, so `lastStepAt` is a fact: if it
//    keeps refreshing, the pass is alive; if it ages, it is not. This is the half that must never lie,
//    so it is reported as an age ("last step 3 s ago") rather than as a verdict.
//  • REMAINING is an estimate, and an early one is worthless: the first days of a pass may be REUSED
//    (fingerprint matched, near-instant) while later ones are re-scored (10–18 s each on a deep raw
//    library), so a mean taken over two reused days would promise a finish that cannot happen. It is
//    therefore withheld until enough days have completed for the mean to mean anything, and shown as an
//    approximation when it is shown at all.

/// A snapshot of a running analysis pass. `nil` on the engine means no pass is in flight.
///
/// Written once per day from inside the detached scan loop (through a main-actor hop) plus once for each
/// surrounding stage, so it costs one published write per ~15 s of work — nothing next to the pass.
struct AnalysisProgress: Equatable, Sendable {

    /// Where the pass is. The day loop is the long part, but it is not the whole pass: the history reads
    /// and baseline folds before it, and the persist + window reconciliation after it, both take real time
    /// on a deep library. Showing "day 0 of 21" through either would look stalled while it is not.
    enum Stage: Equatable, Sendable {
        /// History reads + baseline folds, before the day loop.
        case preparing
        /// Inside the per-day scan.
        case scanning
        /// Persisting scores and reconciling the window, after the day loop.
        case finishing
    }

    var stage: Stage
    /// Days the loop has STARTED past, i.e. how many are behind it. 0 during `.preparing`.
    var completedDays: Int
    /// How many of those days were REUSED — their persisted fingerprint still matched, so nothing was
    /// re-derived from raw. Load-bearing for the copy, not decoration: the loop walks the whole window
    /// even when almost none of it is real work, so a bare "day 7 of 21" reads exactly like the full
    /// re-derivation this stopped doing. A wearer watching the counter race to 21 in a few seconds
    /// concluded, reasonably, that nothing had changed.
    var reusedDays: Int = 0
    /// The window this pass was asked for (`maxDays`).
    var totalDays: Int
    /// When the pass began — the anchor for the elapsed time the estimate divides.
    var startedAt: Date
    /// When the last step was published. The freshness signal: this is what separates "working" from
    /// "stopped", and it is the only claim here that is observed rather than inferred.
    var lastStepAt: Date

    // MARK: - Derivations (pure)

    /// Completed fraction, clamped. `.finishing` reads as full: every day is behind it, and a bar that
    /// sits at 20/21 through the persist phase invites the "it's stuck" reading this whole file exists
    /// to prevent. `.preparing` reads as 0 for the same reason in the other direction.
    var fraction: Double {
        switch stage {
        case .preparing: return 0
        case .finishing: return 1
        case .scanning:
            guard totalDays > 0 else { return 0 }
            return min(1, max(0, Double(completedDays) / Double(totalDays)))
        }
    }

    /// Days completed before the mean per day is worth extrapolating from. Below this the sample is
    /// dominated by whether the first days happened to be reused, which says nothing about the rest.
    static let minDaysForEstimate = 3
    /// Elapsed seconds below which no estimate is offered regardless of day count — a pass that has run
    /// for two seconds has not measured anything yet.
    static let minElapsedForEstimate: TimeInterval = 5
    /// How long without a published step before the card stops saying "working" and starts reporting the
    /// gap. A scanned day is 10–18 s on a deep library, so this is several times the expected step: long
    /// enough that a slow day never cries stall, short enough that a real one surfaces within a minute or
    /// two rather than being waited out.
    static let stallSeconds: TimeInterval = 120

    /// Seconds still to go, or nil when there is not yet enough evidence to say (see the two gates above,
    /// and the stages, which have no day rate to extrapolate from).
    ///
    /// Deliberately a plain mean over completed days rather than a weighted model: the split between
    /// reused and re-scored days in the REMAINDER is unknowable, so a cleverer formula would only be
    /// confidently wrong. The mean converges as the pass runs, which is the honest behaviour — the number
    /// moves as it learns.
    func estimatedSecondsRemaining(now: Date) -> TimeInterval? {
        guard stage == .scanning, totalDays > 0, completedDays >= Self.minDaysForEstimate else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= Self.minElapsedForEstimate else { return nil }
        let remaining = totalDays - completedDays
        guard remaining > 0 else { return nil }
        return (elapsed / Double(completedDays)) * Double(remaining)
    }

    /// True when no step has been published for longer than `stallSeconds`. Reports the OBSERVATION, not
    /// a diagnosis: the pass may be inside one unusually slow day. The copy built from it says how long
    /// it has been quiet and lets the reader draw the conclusion.
    func looksStalled(now: Date) -> Bool {
        now.timeIntervalSince(lastStepAt) >= Self.stallSeconds
    }

    /// Seconds since the last published step — the freshness read-out.
    func secondsSinceLastStep(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(lastStepAt))
    }
}

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
