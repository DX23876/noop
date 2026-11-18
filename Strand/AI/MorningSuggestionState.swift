import Foundation

/// The card's visible state, resolved purely so it can be tested without SwiftUI.
enum MorningSuggestionState: Equatable {
    case hidden
    case generating
    case waiting(PlanProposal)
    /// Last night's window isn't settled yet, so no brief was written. Rather than an empty card, ask
    /// about the one thing that would fix it — the detected wake time (unix seconds).
    case confirmWake(detectedWake: Int)

    /// A waiting proposal for today wins over everything — REGARDLESS of `morningOn` (#R-auto-session):
    /// that toggle only gates the PROACTIVE morning brief (`maybeGenerate()`'s own separate guard); it was
    /// never meant to hide a proposal that already exists, e.g. one the coach recorded because the user
    /// stated a plain-language training intent in an ordinary chat message. Show it even mid-send, since it
    /// IS the outcome. Otherwise show the spinner only while a send is actually in flight AND the user has
    /// opted into the proactive nudge. Everything else — not configured, no consent, a provider that can't
    /// run tools (so no proposal could ever exist), or nothing pending and the opt-in off — is hidden.
    /// `unsettledWake` is the detected wake of a night the data can't yet support. It is answered FIRST,
    /// before every coach gate (2026-11-18).
    ///
    /// It used to sit last, behind `configured`, `consent`, `toolsActive` and `morningOn`, which read as
    /// caution and was a fault: a night the strap has not finished handing over has nothing to do with a
    /// coach. On Android this state has no other home at all, so the gate hid it from every wearer without
    /// a provider — they were never told their recovery was computed on a truncated night, and the wake
    /// time they could have corrected stayed wrong. iOS only escaped it because Today's timeline asks the
    /// same question by a different route; the classic card was just as blind.
    ///
    /// It also wins over a waiting proposal, which is new. A proposal is advice built on last night's
    /// numbers; if those numbers are still moving, saying so first is the honest order.
    static func resolve(
        morningOn: Bool, configured: Bool, consent: Bool, toolsActive: Bool,
        sending: Bool, pending: [PlanProposal], today: String,
        unsettledWake: Int? = nil
    ) -> MorningSuggestionState {
        if let unsettledWake { return .confirmWake(detectedWake: unsettledWake) }
        guard configured, consent, toolsActive else { return .hidden }
        if let p = pending.first(where: { $0.day == today }) { return .waiting(p) }
        guard morningOn else { return .hidden }
        if sending { return .generating }
        return .hidden
    }
}
