import Foundation

/// Non-performance milestones — progress worth noticing that isn't a number on a chart.
///
/// Deliberately NOT streaks or gamification (see the roadmap's "bewusst nicht" list): nothing here
/// counts consecutive days or rewards a habit loop. Each entry states a fact about what actually
/// happened — a week in, a session done, a run completed, a stretch without pain — so the page reads as
/// a record, not a score to keep up.
///
/// Pure and side-effect-free: every input is a plain value the caller already has, so this is testable
/// with no app, no store, no strap.
enum JourneyMilestones {

    struct Milestone: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    struct Inputs: Equatable {
        var daysSinceGoalCreated: Int = 0
        /// Sessions completed since the goal was set (not all-time app usage).
        var completedSessionCount: Int = 0
        var longestRunKm: Double?
        /// Mean trusted Charge over the last ~7 days, and the ~7 days before that — for a plain
        /// week-over-week read, not a trend line.
        var recentAvgCharge: Double?
        var priorAvgCharge: Double?
        /// True when a session was skipped for pain or illness within the last week — gates the
        /// "training pain-free" milestone honestly rather than always claiming it.
        var hasRecentCautionSkip: Bool = false

        init(daysSinceGoalCreated: Int = 0, completedSessionCount: Int = 0, longestRunKm: Double? = nil,
             recentAvgCharge: Double? = nil, priorAvgCharge: Double? = nil,
             hasRecentCautionSkip: Bool = false) {
            self.daysSinceGoalCreated = daysSinceGoalCreated
            self.completedSessionCount = completedSessionCount
            self.longestRunKm = longestRunKm
            self.recentAvgCharge = recentAvgCharge
            self.priorAvgCharge = priorAvgCharge
            self.hasRecentCautionSkip = hasRecentCautionSkip
        }
    }

    /// Charge points a week-over-week rise must clear before it's called out — small week-to-week noise
    /// is normal and shouldn't read as a milestone.
    static let recoveryTrendThreshold: Double = 3.0

    /// What's been achieved so far, in a stable, sensible reading order. Empty is a normal, correct
    /// answer for a goal set five minutes ago — there is nothing dishonest about having nothing yet.
    static func achieved(_ inputs: Inputs) -> [Milestone] {
        var out: [Milestone] = []

        if inputs.daysSinceGoalCreated >= 7 && inputs.completedSessionCount >= 1 {
            out.append(Milestone(id: "first_week", title: "First week in",
                                 detail: "You've stuck with it for a week."))
        }
        if inputs.completedSessionCount >= 1 {
            let n = inputs.completedSessionCount
            out.append(Milestone(id: "sessions",
                                 title: "\(n) session\(n == 1 ? "" : "s") completed",
                                 detail: "Since you set this goal."))
        }
        if let longest = inputs.longestRunKm, longest > 0 {
            out.append(Milestone(id: "longest_run",
                                 title: String(format: "Longest run: %.1f km", longest),
                                 detail: "Your furthest since setting this goal."))
        }
        if !inputs.hasRecentCautionSkip && inputs.completedSessionCount >= 3 {
            out.append(Milestone(id: "pain_free", title: "Training pain-free",
                                 detail: "No pain or illness skips in the last week."))
        }
        if let recent = inputs.recentAvgCharge, let prior = inputs.priorAvgCharge,
           recent > prior + recoveryTrendThreshold {
            out.append(Milestone(id: "recovery_up", title: "Recovery trending up",
                                 detail: "This week's Charge is running higher than last week's."))
        }
        return out
    }

    /// One encouraging, forward-looking line. Never a countdown, never a gap called out as a shortfall —
    /// a goal with nothing achieved yet gets an invitation, not a deficit.
    static func nextSuggestion(_ inputs: Inputs) -> String {
        if inputs.completedSessionCount == 0 {
            return "Complete your first session to get this started."
        }
        if inputs.daysSinceGoalCreated < 7 {
            return "Keep going — a full first week is next."
        }
        if let longest = inputs.longestRunKm, longest > 0 {
            return String(format: "See if you can beat %.1f km next time out.", longest)
        }
        return "Keep showing up — consistency is what moves everything else."
    }
}
