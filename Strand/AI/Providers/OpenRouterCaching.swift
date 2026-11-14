import Foundation

/// Prompt caching for OpenRouter, which is a pass-through gateway: a `cache_control` marker in an
/// OpenAI-shaped request reaches the upstream vendor that actually implements caching.
///
/// Kept in its own file for the same reason `AnthropicCaching.swift` is — the shared
/// `OpenAICompatible*` files stay about the wire format, and this stays about one provider's caching.
///
/// **Only Anthropic-family models.** OpenAI-family models cache automatically and report
/// `cached_tokens` back (already read by `parseOpenAIUsage`), so a marker there would be noise at best.
/// Anthropic's caching is opt-in per request and does nothing without the marker — which is why the
/// direct Anthropic path has carried one since it was written (`AnthropicClient.cacheableSystem`) while
/// the same prompt, sent through OpenRouter to the same model, has been paying full price for every
/// round. Restricted by id prefix rather than extended to every vendor OpenRouter fronts: the marker is
/// only known-correct where it has been checked, and a guess costs a silently mis-shaped request.
enum OpenRouterCaching {

    /// Whether `model` is an Anthropic-family id as OpenRouter names them (`anthropic/claude-…`,
    /// including the `-fast` and `:beta`-style variants, which keep the vendor prefix).
    static func supportsCacheControl(model: String) -> Bool {
        model.hasPrefix("anthropic/")
    }

    /// The `system` wire message.
    ///
    /// The plain-string form for everything else — byte-identical to what both OpenAI-compatible paths
    /// sent before this existed, so no other provider's request shape moves. For an Anthropic model it
    /// becomes the content-parts form carrying the breakpoint, which is the only shape `cache_control`
    /// can be attached to.
    ///
    /// One breakpoint, on the system block, matching the direct Anthropic path's reasoning: Anthropic
    /// renders `tools` → `system` → `messages`, so a breakpoint there caches the tool definitions and
    /// the prompt together — and that pair is exactly what the tool loop re-sends on every round, up to
    /// `maxToolRounds` per question. Caching is a prefix match, so nothing live may be interpolated into
    /// either half; both are stable across a chat by construction.
    static func systemMessage(_ systemPrompt: String, model: String) -> [String: Any] {
        guard supportsCacheControl(model: model) else {
            return ["role": "system", "content": systemPrompt]
        }
        return [
            "role": "system",
            "content": [
                ["type": "text",
                 "text": systemPrompt,
                 "cache_control": ["type": "ephemeral"]]
            ]
        ]
    }
}

extension OpenRouterClient {
    /// Satisfies the identically-named requirement on BOTH `OpenAICompatibleToolClient` and
    /// `OpenAICompatibleStreamingClient` — one concrete method, so the tool loop and the streaming loop
    /// cannot end up caching differently.
    func systemMessage(_ systemPrompt: String, model: String) -> [String: Any] {
        OpenRouterCaching.systemMessage(systemPrompt, model: model)
    }
}
