import Foundation

/// A provider client that can STREAM the assistant reply token-by-token (optionally running the same
/// tool-use rounds as `ToolCallingClient` along the way). Providers opt in by conforming — Anthropic
/// today (see `AnthropicStreaming.swift`); the engine falls back to the non-streaming path for the rest.
/// Declared here rather than in `AIProvider.swift` so tracking upstream never conflicts on the protocol.
protocol StreamingToolClient {
    /// Stream a reply, delivering each text delta through `onDelta` as it arrives, and return the full
    /// final assistant text plus which tools grounded it (the evidence chain, P6). When `tools` is
    /// non-empty the model may request tools mid-stream; `runTool` executes a call by name and its
    /// result is fed back for the next round. `onDelta` runs on the main actor so it can mutate the
    /// engine's published chat directly.
    func streamWithTools(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        tools: [CoachTool],
        runTool: (String, [String: Any]) async -> String,
        onDelta: @MainActor (String) -> Void,
        session: URLSession
    ) async throws -> CoachToolReply
}
