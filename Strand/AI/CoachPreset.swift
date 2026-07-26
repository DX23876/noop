import Foundation

/// A one-tap bundle of the coaching-style settings that otherwise have to be set one at a time
/// (persona, voice, emoji, proactive messages, reply length). Applying a preset only writes into the
/// SAME stores those individual controls already read from (`CoachPersona`, `CoachIdentityStore.voice`,
/// `AICoachEngine.allowEmoji` / `.proactiveLevel` / `.verbosity`) — it is a convenience starting point,
/// not a separate source of truth, so every value it sets stays individually overridable afterwards.
enum CoachPreset: String, CaseIterable, Identifiable {
    case focused
    case supportive
    case onDemand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focused:    return "Focused & brief"
        case .supportive: return "Warm & thorough"
        case .onDemand:   return "Only when asked"
        }
    }

    var subtitle: String {
        switch self {
        case .focused:    return "Commander persona, short replies, only important nudges"
        case .supportive: return "Friend persona, longer explanations, celebrates small wins too"
        case .onDemand:   return "Guardian persona, never messages first"
        }
    }

    var symbol: String {
        switch self {
        case .focused:    return "bolt.fill"
        case .supportive: return "hand.wave.fill"
        case .onDemand:   return "moon.zzz.fill"
        }
    }

    /// The values this preset sets, as a pure struct — kept separate from `apply(...)` so the mapping
    /// itself is testable without touching UserDefaults or the main actor.
    struct Values: Equatable {
        var persona: CoachPersona
        var voice: CoachVoice
        var allowEmoji: Bool
        var proactiveLevel: ProactiveLevel
        var verbosity: CoachVerbosity
    }

    var values: Values {
        switch self {
        case .focused:
            return Values(persona: .commander, voice: .grounded, allowEmoji: false,
                          proactiveLevel: .important, verbosity: .concise)
        case .supportive:
            return Values(persona: .friend, voice: .warm, allowEmoji: true,
                          proactiveLevel: .normal, verbosity: .detailed)
        case .onDemand:
            return Values(persona: .guardian, voice: .neutral, allowEmoji: false,
                          proactiveLevel: .off, verbosity: .normal)
        }
    }

    /// Write this preset's bundle into the live stores. Each value lands exactly where its own settings
    /// control already reads from, so the picker rows update immediately and stay individually editable.
    @MainActor
    func apply(to engine: AICoachEngine, identity: CoachIdentityStore = .shared) {
        let v = values
        engine.persona = v.persona
        identity.setVoice(v.voice)
        engine.allowEmoji = v.allowEmoji
        engine.proactiveLevel = v.proactiveLevel
        engine.verbosity = v.verbosity
    }
}
