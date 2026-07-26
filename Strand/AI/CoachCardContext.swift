import Foundation

/// Card-AI (#P11): a small coach entry point that lives on a metric card (Stress, HRV, Recovery …). When
/// tapped it hands the coach the ONE thing that card already shows — its current value and recent trend —
/// so the coach can give a short, careful read of that metric (11.1/11.2/11.4) instead of the user having
/// to retype "why is my stress high today?" into a blank chat.
///
/// The context is built by the card from data it has ALREADY loaded, so nothing new is derived and no raw
/// signal leaves the device beyond the compact `summary` the coach would otherwise fetch via a tool.
struct CoachCardContext: Equatable {
    /// The metric's display name, e.g. "Stress". Used as the reply's title and in the request line.
    let title: String
    /// A compact, factual line the card already computed — current value plus its recent trend. This is
    /// exactly what the coach reads; it is not re-derived here.
    let summary: String
    /// A few metric-specific follow-up questions, offered as tappable chips after the read (11.3).
    let suggestions: [String]

    init(title: String, summary: String, suggestions: [String] = []) {
        self.title = title
        self.summary = summary
        self.suggestions = suggestions
    }
}

extension Notification.Name {
    /// Posted by a card's `CoachCardButton` to open the Coach on top of the current context. The shells
    /// route it exactly like `.noopOpenCoachCheckIn`; CoachView then consumes the engine's pending card
    /// context and produces the short read.
    static let noopOpenCoachCard = Notification.Name("noop.openCoachCard")
}
