import Foundation

/// How long the coach's replies are allowed to run. A user-set dial, independent of
/// `CoachOutputBudget.maxTokens` (that's an outlier ceiling, not a length target) — this instead adds a
/// plain-language instruction to the system prompt, so `concise` genuinely shortens ordinary replies
/// rather than just capping runaway ones.
enum CoachVerbosity: String, CaseIterable, Identifiable, Codable {
    case concise, normal, detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .concise: return "Concise"
        case .normal:  return "Normal"
        case .detailed: return "Detailed"
        }
    }

    var blurb: String {
        switch self {
        case .concise: return "Short, to-the-point replies — the prescription, not the essay."
        case .normal: return "The coach's usual length — enough to explain the why."
        case .detailed: return "Longer replies with more reasoning and context."
        }
    }

    /// Appended to every system prompt (see `AICoachEngine.systemPrompt`). `normal` is the coach's
    /// existing default register, so it adds no instruction at all — only `concise`/`detailed` steer it.
    var promptClause: String? {
        switch self {
        case .concise:
            return "Keep replies short — a few sentences at most. Lead with the prescription or answer, " +
                "skip preamble, and only add reasoning if it changes what the user should do."
        case .normal:
            return nil
        case .detailed:
            return "You may go longer than usual here — walk through the reasoning behind a recommendation " +
                "and add relevant context, without padding or repeating yourself."
        }
    }

    static let storageKey = "ai.verbosity"
}
