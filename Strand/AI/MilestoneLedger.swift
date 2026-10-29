import Foundation
import StrandAnalytics

/// The bookkeeping behind milestone notifications, kept pure so it can be tested. The stored count is
/// the highest one reached, so a reading that dips below a mark and comes back (a four-week resting
/// heart rate hovering at 55) does not announce the same mark again.
enum MilestoneLedger {
    /// The route a count belongs to: a new target or another spacing gives a different list of marks,
    /// and a count from the old list says nothing about the new one.
    static func route(_ window: LongTermGoalMath.MilestoneWindow) -> String {
        "\(window.values.count)|\(window.values.first ?? 0)|\(window.values.last ?? 0)"
    }

    /// The count to keep and how many marks are new. A goal seen for the first time, or on a changed
    /// route, only records where it stands. Counts stored before routes were kept compare as they are.
    static func advance(high: Int?, storedRoute: String?, window: LongTermGoalMath.MilestoneWindow)
        -> (high: Int, fresh: Int) {
        let reached = window.reachedCount
        guard let high, storedRoute == nil || storedRoute == route(window) else { return (reached, 0) }
        return (max(high, reached), max(0, reached - high))
    }
}
