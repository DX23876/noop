import Foundation

/// Tool-calling for OpenAI-compatible providers. OpenAI itself and OpenRouter both speak the SAME
/// chat-completions "tools" wire format (OpenRouter is a pass-through gateway over it), so one
/// implementation serves both instead of writing it twice for an identical shape. `OpenAIClient` and
/// `OpenRouterClient` each conform via a tiny extension supplying only what differs — the endpoint and
/// how the key is attached — everything else lives here.
///
/// Mirrors `AnthropicTools.swift`'s shape (`maxToolRounds = 5`, and — after B1's fix to the Anthropic
/// side — a forcing final call that keeps the gathered tool data instead of discarding it) with a
/// different wire format: `tools: [{type: "function", function: {name, description, parameters}}]`
/// instead of Anthropic's flat `{name, description, input_schema}`, and a tool round shows up as
/// `message.tool_calls` (each with a JSON-string `arguments`) rather than `tool_use` content blocks. The
/// reply continues with one `{"role": "tool", "tool_call_id": …, "content": …}` turn per call.
///
/// This does NOT save tokens — a lean tool-mode note plus ~3k tokens of tool definitions, resent every
/// round, usually costs MORE than the pre-baked context path for a simple question. It's a capability
/// argument: `propose_plan`, `remember_fact`, `plot_metric`, and the rest become reachable outside
/// Anthropic. Tool execution and consent-gating (`runCoachTool`) are untouched — this file only differs
/// in wire format.
///
/// Gemini and Custom deliberately do NOT get this (user decision): Gemini's tool format is its own shape
/// (a second, unrelated test surface); Custom's tool support depends on BOTH the server and the model,
/// and many local models fail silently or return malformed JSON instead of a clean error.
protocol OpenAICompatibleToolClient: ToolCallingClient {
    var toolChatEndpoint: URL { get }
    func authorizeToolRequest(_ req: inout URLRequest, key: String)
}

extension OpenAIClient: OpenAICompatibleToolClient {
    var toolChatEndpoint: URL { AIProvider.openAI.endpoint }
    func authorizeToolRequest(_ req: inout URLRequest, key: String) {
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
}

extension OpenRouterClient: OpenAICompatibleToolClient {
    var toolChatEndpoint: URL { AIProvider.openRouter.endpoint }
    func authorizeToolRequest(_ req: inout URLRequest, key: String) {
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
}

extension OpenAICompatibleToolClient {

    static var maxToolRounds: Int { 5 }   // mirrors AnthropicTools.maxToolRounds

    func sendWithTools(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        tools: [CoachTool],
        runTool: (String, [String: Any]) async -> String,
        session: URLSession
    ) async throws -> CoachToolReply {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }
        let toolSpecs = tools.map { $0.openAIFunctionSpec }
        // Decided at most once per conversation, not per round: if round 1 needs the modern param shape,
        // every later round will too (same model, same server) — mirrors OpenAIClient.send's own retry.
        var modernParams = false
        // The evidence chain (P6): every tool name actually called, in call order, across every round.
        var calledTools: [String] = []

        for _ in 0..<Self.maxToolRounds {
            let message = try await roundOrRetry(key: key, model: model, wire: wire, tools: toolSpecs,
                                                 modernParams: &modernParams, session: session)

            let calls = Self.toolCalls(in: message)
            if !calls.isEmpty {
                // Echo the assistant's tool-call turn EXACTLY as the model produced it — the API requires
                // this turn to precede the matching tool-result turns.
                wire.append(message)
                for call in calls {
                    guard let parsed = Self.parseToolCall(call) else { continue }
                    let output = await runTool(parsed.name, parsed.input)
                    calledTools.append(parsed.name)
                    wire.append(["role": "tool", "tool_call_id": parsed.id, "content": output])
                }
                continue
            }
            return CoachToolReply(text: (message["content"] as? String) ?? "", toolsUsed: calledTools)
        }

        // Exhausted the round cap without a final answer: one last call WITHOUT tools forces text, with
        // the gathered tool data folded into the closing turn (B1's fix, same shape here).
        let closing = try await roundOrRetry(key: key, model: model, wire: Self.closingWire(from: wire),
                                             tools: [], modernParams: &modernParams, session: session)
        return CoachToolReply(text: (closing["content"] as? String) ?? "", toolsUsed: calledTools)
    }

    /// One request, transparently retried once with the modern param shape (`max_completion_tokens`, no
    /// `temperature`) on the exact 400 signature `OpenAIClient.send` already retries — reasoning models
    /// reject the classic shape. `modernParams` is `inout` so a retry on round 1 sticks for every later
    /// round instead of re-discovering it each time.
    private func roundOrRetry(
        key: String, model: String, wire: [[String: Any]], tools: [[String: Any]],
        modernParams: inout Bool, session: URLSession
    ) async throws -> [String: Any] {
        do {
            return try await chatRound(key: key, model: model, wire: wire, tools: tools,
                                       modernParams: modernParams, session: session)
        } catch let AICoachError.server(code, detail) where code == 400 && !modernParams {
            let d = detail.lowercased()
            guard d.contains("max_completion_tokens") || d.contains("max_tokens")
                || d.contains("temperature") || d.contains("unsupported") else {
                throw AICoachError.server(code, detail)
            }
            modernParams = true
            return try await chatRound(key: key, model: model, wire: wire, tools: tools,
                                       modernParams: modernParams, session: session)
        }
    }

    private func chatRound(
        key: String, model: String, wire: [[String: Any]], tools: [[String: Any]],
        modernParams: Bool, session: URLSession
    ) async throws -> [String: Any] {
        var body: [String: Any] = ["model": model, "messages": wire]
        if !tools.isEmpty { body["tools"] = tools }
        if modernParams {
            body["max_completion_tokens"] = CoachOutputBudget.maxTokens
        } else {
            body["temperature"] = 0.6
            body["max_tokens"] = CoachOutputBudget.maxTokens
        }

        var req = URLRequest(url: toolChatEndpoint)
        req.httpMethod = "POST"
        authorizeToolRequest(&req, key: key)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw AICoachError.decode
        }
        return message
    }

    // MARK: - Pure (no network — unit-tested)

    /// The tool_calls array on an assistant message, or empty when this round is a final answer.
    static func toolCalls(in message: [String: Any]) -> [[String: Any]] {
        (message["tool_calls"] as? [[String: Any]]) ?? []
    }

    /// Parse one `tool_calls` entry into (id, name, decoded arguments). Malformed entries are skipped
    /// rather than thrown — one bad call shouldn't abort a round that may contain good ones alongside it.
    static func parseToolCall(_ call: [String: Any]) -> (id: String, name: String, input: [String: Any])? {
        guard let id = call["id"] as? String,
              let fn = call["function"] as? [String: Any],
              let name = fn["name"] as? String else { return nil }
        let argsString = fn["arguments"] as? String ?? "{}"
        let input = (try? JSONSerialization.jsonObject(with: Data(argsString.utf8))) as? [String: Any] ?? [:]
        return (id, name, input)
    }

    /// Reduce the accumulated tool-call transcript to a tool-less request body, folding gathered `tool`
    /// results into a closing user turn instead of discarding them — the OpenAI-format twin of B1's fix
    /// to `AnthropicTools.messagesForFinal` (that fix exists because the closing instruction below says
    /// "using the data gathered above": dropping the tool turns must not make that a lie).
    static func closingWire(from wire: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var gathered: [String] = []
        for turn in wire {
            guard let role = turn["role"] as? String else { continue }
            if role == "tool" {
                if let c = turn["content"] as? String, !c.isEmpty { gathered.append(c) }
                continue
            }
            // An assistant turn whose content is nil (pure tool_calls, no accompanying text) contributes
            // nothing readable here and is dropped; its tool_calls have no matching endpoint anymore.
            if let s = turn["content"] as? String, !s.isEmpty {
                out.append(["role": role, "content": s])
            }
        }
        var closing = "Answer now using the data gathered above. Do not request more tools."
        if !gathered.isEmpty {
            closing = "Data gathered by the tools so far:\n\n" + gathered.joined(separator: "\n\n")
                + "\n\n" + closing
        }
        out.append(["role": "user", "content": closing])
        return out
    }
}
