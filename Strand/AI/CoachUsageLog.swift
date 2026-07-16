import Foundation

/// Per-turn token accounting for the coach's own API calls. On-device only: these counters are read from
/// the provider's reply, shown in Coach settings, and never stored or sent anywhere.
///
/// This exists for one reason. Anthropic's prompt cache only engages once the cached prefix clears a
/// model-dependent minimum length; below it the cache silently does nothing — no error, no warning, no
/// saving. Without the counters there is no way to tell "caching works" from "caching never engaged", so
/// the numbers ship alongside the feature rather than as an afterthought.
///
/// A *turn* is one user question, which the tool loop may spread across several requests (see
/// `AnthropicClient.maxToolRounds`); each request is one `Round`.
@MainActor
final class CoachUsageLog: ObservableObject {

    static let shared = CoachUsageLog()

    /// One request's token counts, taken straight from the provider's `usage` object.
    struct Round: Equatable {
        /// Processed at full price — everything neither read from nor written to the cache.
        var inputTokens = 0
        /// Served FROM the cache at roughly a tenth of the input price. The number that proves a hit.
        var cacheReadTokens = 0
        /// Written TO the cache at roughly 1.25x, paid once by the round that seeds it.
        var cacheWriteTokens = 0
        var outputTokens = 0
    }

    /// Every round of one question, so a multi-round tool answer reports its true total.
    struct Turn: Equatable {
        var rounds: [Round] = []

        var inputTokens: Int { rounds.reduce(0) { $0 + $1.inputTokens } }
        var cacheReadTokens: Int { rounds.reduce(0) { $0 + $1.cacheReadTokens } }
        var cacheWriteTokens: Int { rounds.reduce(0) { $0 + $1.cacheWriteTokens } }
        var outputTokens: Int { rounds.reduce(0) { $0 + $1.outputTokens } }
    }

    @Published private(set) var lastTurn: Turn?

    private var current = Turn()

    /// Start counting a new question. Called by the provider at the top of its tool loop.
    func beginTurn() { current = Turn() }

    func record(_ round: Round) {
        current.rounds.append(round)
        lastTurn = current
    }

    // MARK: - Diagnostic text

    /// A plain-language read of what the cache actually did. Pure and testable — no network, no state,
    /// hence `nonisolated`: it reads its argument and nothing else.
    ///
    /// The "no caching" case is the whole point: a prefix below the model's minimum cacheable length
    /// fails silently at the API, so this line is the only place that failure becomes visible.
    nonisolated static func cacheVerdict(for turn: Turn) -> String {
        if turn.cacheReadTokens > 0 {
            return "Cache hit — \(turn.cacheReadTokens) tokens served from cache at about a tenth of the price."
        }
        if turn.cacheWriteTokens > 0 {
            return "Cache written (\(turn.cacheWriteTokens) tokens), not read yet. The next question in this "
                + "chat should read it back."
        }
        return "No caching. The cached part of this request is likely shorter than the minimum your model "
            + "requires, so the cache never engaged. Nothing is broken and nothing extra was charged — "
            + "there is just no saving."
    }

    /// One-line token summary for the settings diagnostic. Pure and testable.
    nonisolated static func summaryLine(for turn: Turn) -> String {
        let n = turn.rounds.count
        return "\(n) request\(n == 1 ? "" : "s") · \(turn.inputTokens) in · "
            + "\(turn.cacheReadTokens) cached · \(turn.outputTokens) out"
    }
}
