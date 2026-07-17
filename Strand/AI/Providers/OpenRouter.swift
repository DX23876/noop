import Foundation

/// A single entry from OpenRouter's `/models` catalogue — richer than a bare id, so the searchable
/// picker can show context length and price, and so a later tool-calling gate (P9) can read whether a
/// model supports tools without a second request. Parsed once in `parseModelDetails`, never invented.
struct OpenRouterModel: Identifiable, Equatable {
    let id: String
    let name: String
    let contextLength: Int?
    /// USD per 1M tokens — OpenRouter's own `/models` reports per-token price as a decimal string;
    /// this is that value scaled ×1,000,000 for a number worth showing in the UI.
    let promptPricePerMillion: Double?
    let completionPricePerMillion: Double?
    /// From `supported_parameters` containing `"tools"` — whether this specific model can be handed
    /// function/tool definitions at all. Not every model behind OpenRouter can; P9's tool-calling gate
    /// reads this rather than assuming every OpenRouter model behaves like Anthropic's.
    let supportsTools: Bool
}

/// OpenRouter (`https://openrouter.ai`) — a single OpenAI-compatible gateway in front of 300+ models
/// from many vendors. Deliberately its own client rather than routing through `CustomClient`: the base
/// URL here is FIXED and always `https`, so `AIProvider.guardCustomBaseURL()`'s cleartext-LAN guard
/// (built for a user-typed local-server URL) has nothing to check and doesn't apply.
///
/// No `HTTP-Referer` / `X-Title` ranking headers: OpenRouter's docs describe them as opt-in attribution
/// for their public model-ranking page, and this fork ships no telemetry and stays anonymous by design
/// (see `CLAUDE.md`) — sending either would tell a third party which app is asking. Omitted rather than
/// guessed at being harmless.
struct OpenRouterClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        let body: [String: Any] = [
            "model": model,
            "messages": wire,
            "temperature": 0.6,
            "max_tokens": CoachOutputBudget.maxTokens
        ]

        var req = URLRequest(url: AIProvider.openRouter.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        return try parseChatContent(json)
    }

    /// Pure: unwrap an OpenAI-compatible chat-completions body, appending a truncation note when the
    /// model stopped early. OpenRouter fronts hosted models exclusively (never a local Ollama-style
    /// server), so unlike `CustomClient` there is only ever one cause worth naming — the output cap.
    /// No network — unit-tested.
    func parseChatContent(_ json: [String: Any]) throws -> String {
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AICoachError.decode
        }
        if (first["finish_reason"] as? String)?.lowercased() == "length" {
            return content + "\n\n---\n*Reply cut off: that's the reply length rather than the "
                + "context window — ask a narrower question, or pick a model with a higher output limit.*"
        }
        return content
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        try await fetchModelDetails(key: key, session: session).map { $0.id }
    }

    /// The richer fetch the searchable model picker uses. OpenRouter's `/models` needs no key to list
    /// (verified against the live endpoint), but a key is sent when present since `resolvedKey` already
    /// requires one before this is ever called from the settings UI.
    func fetchModelDetails(key: String, session: URLSession) async throws -> [OpenRouterModel] {
        var req = URLRequest(url: AIProvider.openRouter.modelsEndpoint)
        req.httpMethod = "GET"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return parseModelDetails(try await performRequest(req, session: session))
    }

    /// Pure: unwrap OpenRouter's `/models` body into structured entries. No network — unit-tested
    /// against a frozen sample of the real response (`StrandTests/Fixtures/openrouter-models-sample.json`),
    /// not invented JSON (the exact field names/shapes below were verified with a live `curl`, not
    /// written from memory).
    func parseModelDetails(_ json: [String: Any]) -> [OpenRouterModel] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let name = row["name"] as? String ?? id
            let contextLength = row["context_length"] as? Int
            let pricing = row["pricing"] as? [String: Any]
            let promptPrice = (pricing?["prompt"] as? String).flatMap(Double.init).map { $0 * 1_000_000 }
            let completionPrice = (pricing?["completion"] as? String).flatMap(Double.init).map { $0 * 1_000_000 }
            let supportsTools = (row["supported_parameters"] as? [String])?.contains("tools") ?? false
            return OpenRouterModel(id: id, name: name, contextLength: contextLength,
                                   promptPricePerMillion: promptPrice,
                                   completionPricePerMillion: completionPrice,
                                   supportsTools: supportsTools)
        }
    }
}
