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
    /// The Data access purposes the `summary` draws on. A card read sends the summary to the provider, so
    /// every one of them must be granted: tapping "Ask coach" on the Stress card must not carry stress
    /// data past a Stress switch the user turned off. Most cards show core biometrics only.
    let requiredPurposes: Set<CoachPurpose>

    init(title: String, summary: String, suggestions: [String] = [],
         requiredPurposes: Set<CoachPurpose> = [.coreBiometrics]) {
        self.title = title
        self.summary = summary
        self.suggestions = suggestions
        self.requiredPurposes = requiredPurposes
    }

    /// The purposes behind a Today dashboard row's one-line summary. Stress has its own switch in Data
    /// access; every other row there states a core biometric.
    static func purposes(forDashboard route: TabRoute) -> Set<CoachPurpose> {
        if case .stress = route { return [.coreBiometrics, .stress] }
        return [.coreBiometrics]
    }

    /// The purposes behind an Explore chart's summary. A window beyond a month is the long-term trend
    /// Data access describes as "across months or years"; mood is a logged entry, not a sensor reading.
    static func purposes(forExplore source: String, windowDays: Int?) -> Set<CoachPurpose> {
        var purposes: Set<CoachPurpose> = source == "noop-mood" ? [.logs] : [.coreBiometrics]
        if (windowDays ?? Int.max) > 30 { purposes.insert(.longHistory) }
        return purposes
    }

    /// Whether the user's granular grants cover everything this card would send.
    func isAllowed(by consent: ToolConsent) -> Bool {
        requiredPurposes.isSubset(of: consent.enabled)
    }
}

extension Notification.Name {
    /// Posted by a card's `CoachCardButton` to open the Coach on top of the current context. The shells
    /// route it exactly like `.noopOpenCoachCheckIn`; CoachView then consumes the engine's pending card
    /// context and produces the short read.
    static let noopOpenCoachCard = Notification.Name("noop.openCoachCard")
}
