import Foundation

/// A selectable coaching personality that shapes the coach's *voice* without touching its
/// methodology or safety rules. The chosen persona's ``systemPreamble`` is prepended to the
/// prompt built in `AICoachEngine.systemPrompt`, so the built-in coaching logic — and any
/// custom instructions the user has typed — still apply underneath; the persona only changes
/// tone. Kept in its own file so it merges cleanly when tracking the upstream repo.
enum CoachPersona: String, CaseIterable, Identifiable {
    case guardian
    case friend
    case commander

    var id: String { rawValue }

    /// Short display name for the picker.
    var title: String {
        switch self {
        case .guardian:  return "Guardian"
        case .friend:    return "Friend"
        case .commander: return "Commander"
        }
    }

    /// One-line description shown beneath the picker.
    var subtitle: String {
        switch self {
        case .guardian:  return "Calm and balanced"
        case .friend:    return "Warm and encouraging"
        case .commander: return "Direct and action-oriented"
        }
    }

    /// SF Symbol that fronts the persona in the settings card.
    var symbol: String {
        switch self {
        case .guardian:  return "shield.lefthalf.filled"
        case .friend:    return "hand.wave.fill"
        case .commander: return "bolt.fill"
        }
    }

    /// Voice directive prepended to the system prompt. Tone only — it never overrides the
    /// coaching methodology, the "not a doctor" guardrail, or the Markdown formatting rules
    /// that live in `AICoachEngine.defaultSystemPrompt`.
    var systemPreamble: String {
        switch self {
        case .guardian:
            return """
            COACHING VOICE — Guardian: calm, measured and protective. Prioritise the user's \
            long-term health over any single session. Reassure before you push, name risks \
            plainly, and lean toward rest when the data is ambiguous. Steady, grounded sentences.
            """
        case .friend:
            return """
            COACHING VOICE — Friend: warm, encouraging and personal, like a training partner who \
            genuinely cares. Celebrate wins, stay upbeat about setbacks, and keep it conversational \
            and human. Motivate through support, not pressure.
            """
        case .commander:
            return """
            COACHING VOICE — Commander: direct, decisive and action-oriented. Lead with the call, \
            cut the hedging, and give clear orders the user can act on now. Confident and demanding \
            but never reckless — still respect the readiness data and the recovery guardrails.
            """
        }
    }

    // MARK: - Persistence

    /// UserDefaults key holding the selected persona's `rawValue`. Small, non-secret text.
    static let defaultsKey = "ai.persona"

    /// The persona in effect, read fresh so a change takes effect on the very next message.
    /// Defaults to ``friend`` to preserve the app's existing supportive tone for users who
    /// never open the picker.
    static var current: CoachPersona {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(CoachPersona.init(rawValue:)) ?? .friend
    }

    /// Persist the selected persona.
    static func set(_ persona: CoachPersona) {
        UserDefaults.standard.set(persona.rawValue, forKey: defaultsKey)
    }
}
