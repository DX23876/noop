import Foundation

/// Prompt caching + token accounting for the Anthropic tool paths. Kept in its own file so the base
/// `AnthropicClient` (Anthropic.swift) stays untouched and merges cleanly against upstream, matching how
/// `AnthropicTools` and `AnthropicStreaming` are split out.
extension AnthropicClient {

    /// The `system` field as a block array carrying a cache breakpoint.
    ///
    /// Anthropic renders `tools` → `system` → `messages`, so a breakpoint on the last system block caches
    /// the tool definitions **and** the system prompt together. That pair is exactly what the tool loop
    /// re-sends on every round (up to `maxToolRounds` per question), which is where the cost actually is —
    /// not in any single request. Cache reads bill at roughly a tenth of the input price.
    ///
    /// Used only on the tool paths. The plain `send()` carries no tools, so its prefix is the system
    /// prompt alone — short enough to fall under every model's minimum cacheable length, where a
    /// breakpoint does nothing at all. Leaving it out is both correct and keeps that upstream file clean.
    ///
    /// Caching is a prefix match: any byte that changes here invalidates it. The prompt is a stored
    /// constant and the tool list is deterministic, so the pair is stable across a chat — which is the
    /// reason this is worth doing and the reason not to interpolate anything live into either.
    static func cacheableSystem(_ systemPrompt: String) -> [[String: Any]] {
        [["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]]
    }

    /// Pure: read an Anthropic `usage` object into one round of counts. Absent keys read as zero, so a
    /// reply without cache fields reports "no caching" — which is the honest answer, not an error.
    /// No network; unit-tested.
    static func parseUsage(_ usage: [String: Any]) -> CoachUsageLog.Round {
        CoachUsageLog.Round(
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
            cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0
        )
    }

    /// Hand one round's counts to the on-device log. Hops to the main actor because the log drives UI.
    static func recordUsage(_ round: CoachUsageLog.Round) async {
        await MainActor.run { CoachUsageLog.shared.record(round) }
    }

    /// Reset the counters at the start of a question, so the diagnostic reports this turn's rounds only.
    static func beginUsageTurn() async {
        await MainActor.run { CoachUsageLog.shared.beginTurn() }
    }
}
