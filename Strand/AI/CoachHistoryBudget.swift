import Foundation

/// How much CONVERSATION HISTORY a request may carry, in estimated tokens.
///
/// The window used to be a flat message count (`maxHistoryMessages = 10`) — one number for a 2 048-token
/// local Ollama model and for a 200 000-token Claude alike. That is wrong in both directions: it throws
/// away useful context on a large model for no reason, and on a tiny local one ten long turns can still
/// crowd out the reply the user is waiting for.
///
/// Deliberately NOT a real tokenizer. A tokenizer per provider is a dependency, a maintenance burden and
/// a per-request cost, to refine a number that only decides where to cut a conversation. Characters ÷ 4
/// is the standard rough estimate for English and errs slightly *long* on German compounds — i.e. it
/// under-fills the window rather than overflowing it, which is the safe direction to be wrong in.
///
/// The budget covers the history ONLY. The system prompt, the data context, the tool definitions and the
/// reply itself all draw on the same model window, which is why each figure below sits far under the
/// model's real capacity rather than near it.
enum CoachHistoryBudget {

    /// Never send fewer than this many recent messages, whatever the budget says. This is the OLD flat
    /// window, kept as a floor so no provider can come out of this change with less context than before —
    /// including a local server whose budget is deliberately tiny.
    static let minMessages = 10

    /// A local or unknown server. Ollama defaults to a 2 048-token context and llama.cpp is often
    /// smaller; the system prompt and the answer have to fit in there too, so the history gets a modest
    /// slice. The `minMessages` floor still applies, so this never sends less than today's build does.
    static let conservativeTokens = 1_200

    /// A current cloud model (Claude, GPT-4o/4.1, Gemini). All of them carry 128k+ windows, so a few
    /// thousand tokens of history is comfortably affordable — and far more useful than ten messages.
    static let spaciousTokens = 12_000

    /// Estimated tokens for a string: characters ÷ 4, rounded up, never negative.
    static func estimateTokens(_ text: String) -> Int {
        (text.count + 3) / 4
    }

    /// The history budget for a provider/model pair.
    ///
    /// Anthropic, OpenAI and Gemini only serve large-window models today, so they are spacious by
    /// provider. OpenRouter fronts everything from 8k local-scale models to 1M-token ones and Custom
    /// points at whatever the user is running — neither can be judged from the provider alone, so both
    /// are read from the model id and default to conservative. Guessing large on a small model is the
    /// expensive mistake (a hard context overflow, or a silently truncated prompt); guessing small on a
    /// large one only costs some scrollback.
    static func tokens(provider: AIProvider, model: String) -> Int {
        switch provider {
        case .anthropic, .openAI, .gemini:
            return spaciousTokens
        case .openRouter, .custom:
            return isKnownLargeWindow(model) ? spaciousTokens : conservativeTokens
        }
    }

    /// Whether a free-form model id names a family we know carries a large context window. Substring
    /// matching on purpose: OpenRouter ids are `vendor/slug` (`anthropic/claude-sonnet-4.6`) and a local
    /// server's are whatever the user tagged them (`llama3.1:70b-instruct-q4`), so an exact list would
    /// be stale within weeks. Unknown ⇒ conservative.
    static func isKnownLargeWindow(_ model: String) -> Bool {
        let id = model.lowercased()
        return ["claude", "gpt-4o", "gpt-4.1", "gpt-5", "gemini", "mistral-large", "deepseek",
                "qwen2.5", "qwen3", "command-r"].contains { id.contains($0) }
    }
}
