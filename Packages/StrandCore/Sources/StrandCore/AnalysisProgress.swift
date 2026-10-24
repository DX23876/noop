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
public struct AnalysisProgress: Equatable, Sendable {

    /// Where the pass is. The day loop is the long part, but it is not the whole pass: the history reads
    /// and baseline folds before it, and the persist + window reconciliation after it, both take real time
    /// on a deep library. Showing "day 0 of 21" through either would look stalled while it is not.
    public enum Stage: Equatable, Sendable {
        /// History reads + baseline folds, before the day loop.
        case preparing
        /// Inside the per-day scan.
        case scanning
        /// Persisting scores and reconciling the window, after the day loop.
        case finishing
    }

    public var stage: Stage
    /// Days the loop has STARTED past, i.e. how many are behind it. 0 during `.preparing`.
    public var completedDays: Int
    /// How many of those days were REUSED — their persisted fingerprint still matched, so nothing was
    /// re-derived from raw. Load-bearing for the copy, not decoration: the loop walks the whole window
    /// even when almost none of it is real work, so a bare "day 7 of 21" reads exactly like the full
    /// re-derivation this stopped doing. A wearer watching the counter race to 21 in a few seconds
    /// concluded, reasonably, that nothing had changed.
    public var reusedDays: Int = 0
    /// The window this pass was asked for (`maxDays`).
    public var totalDays: Int
    /// When the pass began — the anchor for the elapsed time the estimate divides.
    public var startedAt: Date
    /// When the last step was published. The freshness signal: this is what separates "working" from
    /// "stopped", and it is the only claim here that is observed rather than inferred.
    public var lastStepAt: Date

    public init(stage: Stage, completedDays: Int, reusedDays: Int = 0, totalDays: Int, startedAt: Date,
                lastStepAt: Date) {
        self.stage = stage; self.completedDays = completedDays; self.reusedDays = reusedDays
        self.totalDays = totalDays; self.startedAt = startedAt; self.lastStepAt = lastStepAt
    }

    // MARK: - Derivations (pure)

    /// Completed fraction, clamped. `.finishing` reads as full: every day is behind it, and a bar that
    /// sits at 20/21 through the persist phase invites the "it's stuck" reading this whole file exists
    /// to prevent. `.preparing` reads as 0 for the same reason in the other direction.
    public var fraction: Double {
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
    public static let minDaysForEstimate = 3
    /// Elapsed seconds below which no estimate is offered regardless of day count — a pass that has run
    /// for two seconds has not measured anything yet.
    public static let minElapsedForEstimate: TimeInterval = 5
    /// How long without a published step before the card stops saying "working" and starts reporting the
    /// gap. A scanned day is 10–18 s on a deep library, so this is several times the expected step: long
    /// enough that a slow day never cries stall, short enough that a real one surfaces within a minute or
    /// two rather than being waited out.
    public static let stallSeconds: TimeInterval = 120

    /// Seconds still to go, or nil when there is not yet enough evidence to say (see the two gates above,
    /// and the stages, which have no day rate to extrapolate from).
    ///
    /// Deliberately a plain mean over completed days rather than a weighted model: the split between
    /// reused and re-scored days in the REMAINDER is unknowable, so a cleverer formula would only be
    /// confidently wrong. The mean converges as the pass runs, which is the honest behaviour — the number
    /// moves as it learns.
    public func estimatedSecondsRemaining(now: Date) -> TimeInterval? {
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
    public func looksStalled(now: Date) -> Bool {
        now.timeIntervalSince(lastStepAt) >= Self.stallSeconds
    }

    /// Seconds since the last published step — the freshness read-out.
    public func secondsSinceLastStep(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(lastStepAt))
    }
}
