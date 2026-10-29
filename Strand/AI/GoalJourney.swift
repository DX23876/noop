import Foundation

/// The two rules of a goal's journey page that are not drawing: the countdown line under its title and whether its
/// measured target appears reached. Shared by Apple's `JourneyView` and the Android core (parity plan 2.3).
enum GoalJourney {
    /// "N weeks to go · build phase". A closed goal has no countdown; its closure card already says how it ended.
    static func timeSummary(_ goal: CoachGoal, now: Date = Date()) -> String? {
        guard goal.status == .active else { return nil }
        var parts: [String] = []
        if let weeks = goal.weeksRemaining(from: now) {
            // The passed-date and phase words were never in the catalog; they stay as Apple has always shown them.
            parts.append(weeks < 0 ? "target date has passed"
                                   : String(localized: "\(Int(weeks.rounded())) weeks to go"))
        }
        if let phase = goal.phase(from: now) { parts.append("\(phase) phase") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The measured value has passed the target in the goal's direction. NOOP never closes the goal for it; the
    /// page only asks.
    static func appearsReached(_ goal: CoachGoal, current: Double?) -> Bool {
        guard goal.kind.isQuantified, let baseline = goal.baseline, let target = goal.target,
              target != baseline, let current else { return false }
        return target > baseline ? current >= target : current <= target
    }
}
