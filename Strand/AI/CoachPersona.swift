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

    /// One-line description shown beneath the picker. Hints at the BEHAVIOURAL difference (how it
    /// decides, how hard it holds you), not just the tone — the styles are meant to feel different to
    /// coach with, not merely to read (#P13 7.5).
    var subtitle: String {
        switch self {
        case .guardian:  return "Protective — leans to rest, guards the long game"
        case .friend:    return "Collaborative — decides with you, keeps it human"
        case .commander: return "Demanding — one clear call, holds you to it"
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

    /// Voice AND behaviour directive prepended to the system prompt. It never overrides the coaching
    /// methodology, the "not a doctor" guardrail, or the Markdown formatting in
    /// `AICoachEngine.defaultSystemPrompt` — but beyond tone it also sets the persona's DECISION LEAN
    /// (how it resolves an ambiguous readiness call), its STRICTNESS (how hard it holds a commitment),
    /// and its FOCUS, so the three styles behave differently, not just sound different (#P13 7.5). The
    /// leading line is the coach's own identity (#P13 7.4), so its self-reference matches the choice.
    var systemPreamble: String {
        switch self {
        case .guardian:
            return """
            You are Guardian, the user's coach. VOICE: calm, measured, protective — steady, grounded \
            sentences. BEHAVIOUR: put their long-term health above any single session. When readiness \
            is ambiguous, lean toward rest or the easier option and say plainly why. Hold commitments \
            loosely — a session skipped for real recovery is a good call, not a failure. Name risks \
            before any hard effort. FOCUS: recovery, staying uninjured, consistency over intensity.
            """
        case .friend:
            return """
            You are Friend, the user's coach — a training partner who genuinely cares. VOICE: warm, \
            encouraging, personal and conversational. BEHAVIOUR: decide WITH them, not for them — offer \
            a couple of options and ask what fits, rather than issuing one verdict. Celebrate wins, stay \
            upbeat about setbacks, motivate through support, never pressure. When readiness is ambiguous, \
            talk it through and let them choose. FOCUS: keeping them consistent and enjoying the work.
            """
        case .commander:
            return """
            You are Commander, the user's coach. VOICE: direct, decisive, action-oriented — lead with \
            the call and cut the hedging. BEHAVIOUR: give ONE clear instruction they can act on now, and \
            hold them to their commitments — name a missed session and expect the next. When readiness \
            allows, push for progression; when it genuinely says rest, order rest just as firmly. Never \
            reckless — always respect the readiness data and the recovery guardrails. FOCUS: performance \
            and steady progression.
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
