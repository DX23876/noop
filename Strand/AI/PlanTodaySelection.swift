import Foundation

/// Which committed plan session Today shows, and when it draws attention or reaches Momentum. Moved out of
/// `PlanTodayCard` so the Android core resolves the same session (Android parity plan, Momentum inputs).
enum PlanTodaySelection {
    /// How long BEFORE the session's time it starts drawing attention, and how long AFTER its time it
    /// stays visible and "due" rather than silently vanishing at the moment it matters most.
    static let approachLead: TimeInterval = 30 * 60
    static let graceAfter: TimeInterval = 120 * 60
    static let untimedMomentumReminderHour = 18

    /// Attention level for the plan card, driven purely by the session's time vs `now`. Pure + static so the
    /// windows are testable without a `View`.
    enum Emphasis: Equatable { case none, approaching, due }

    static func emphasis(for proposal: PlanProposal, now: Date) -> Emphasis {
        guard let t = proposal.time else { return .none }   // an untimed commitment has nothing to count to
        if now >= t && now < t.addingTimeInterval(graceAfter) { return .due }
        if now >= t.addingTimeInterval(-approachLead) && now < t { return .approaching }
        return .none
    }

    /// Momentum is an exception surface, not a second copy of the plan. Accepting a suggestion is a
    /// successful decision and must not instantly become a yellow "still open" warning. The ambient
    /// plan card keeps the commitment visible. A timed session reaches Momentum when its start time is
    /// due. An untimed session remains neutral through the day and gets one evening reminder from 18:00.
    static func shouldFlagInMomentum(_ proposal: PlanProposal, now: Date,
                                     calendar: Calendar = .current) -> Bool {
        if proposal.time == nil {
            guard let reminderStart = calendar.date(bySettingHour: untimedMomentumReminderHour,
                                                     minute: 0, second: 0, of: now),
                  now >= reminderStart else { return false }
            // A late acceptance is still a fresh, successful decision. The 18:00 reminder applies to
            // commitments that were already open when the evening boundary arrived, not to one the
            // person accepted at 18:05 while looking at Momentum.
            return proposal.decidedAt.map { $0 < reminderStart } ?? true
        }
        return emphasis(for: proposal, now: now) == .due
    }

    /// The soonest committed session worth showing. Pure + static so the selection rule is testable
    /// without a `View`.
    ///
    /// A timed session shows from acceptance until `graceAfter` past its time (within the next two days),
    /// so the moment you're due or just ran late is exactly when the card is present and emphasised — not
    /// the moment it disappears. An UNTIMED commitment shows too, but only for TODAY: accepting a proposal
    /// records no time (accept is a yes, not a scheduling act), and excluding untimed sessions made Accept
    /// look like it did nothing. A `.completed` session is done, so it never surfaces as "next up".
    static func next(from proposals: [PlanProposal], today: String, now: Date) -> PlanProposal? {
        let horizon = Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now
        return proposals
            .filter { $0.status.isCommitment && $0.status != .completed && $0.day >= today }
            .filter { p in
                if let t = p.time { return t < horizon && t.addingTimeInterval(graceAfter) > now }
                return p.day == today
            }
            .min { ($0.time ?? .distantFuture) < ($1.time ?? .distantFuture) }
    }

}
