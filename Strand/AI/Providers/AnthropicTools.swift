import Foundation

/// Tool-use loop for Anthropic's Messages API, kept in its own file so the base `AnthropicClient`
/// (Anthropic.swift) stays untouched and merges cleanly against upstream. The model may answer directly
/// or emit `tool_use` blocks; we run each requested tool, feed the results back as a `tool_result` turn,
/// and repeat until it produces a final text answer (or we hit the round cap).
extension AnthropicClient: ToolCallingClient {

    /// Hard cap on tool rounds so a model that keeps requesting data can never loop forever. Five rounds
    /// is ample for the coach's handful of tools. Shared with the streaming loop (`AnthropicStreaming`).
    static let maxToolRounds = 5

    func sendWithTools(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        tools: [CoachTool],
        runTool: (String, [String: Any]) async -> String,
        session: URLSession
    ) async throws -> String {
        // Running transcript in Anthropic wire form. Seed it from the chat turns (plain-string content).
        var wire: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let toolSpecs = tools.map { $0.anthropicSpec }
        await Self.beginUsageTurn()

        for _ in 0..<Self.maxToolRounds {
            // `system` rides as a cacheable block array: tools + prompt are re-sent on every round below,
            // so caching that pair is what keeps a multi-round answer from paying for them each time.
            let body: [String: Any] = [
                "model": model,
                "max_tokens": CoachOutputBudget.maxTokens,
                "system": Self.cacheableSystem(systemPrompt),
                "messages": wire,
                "tools": toolSpecs
            ]

            var req = URLRequest(url: AIProvider.anthropic.endpoint)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let json = try await performRequest(req, session: session)
            if let usage = json["usage"] as? [String: Any] {
                await Self.recordUsage(Self.parseUsage(usage))
            }
            guard let content = json["content"] as? [[String: Any]] else { throw AICoachError.decode }

            // Not a tool request → this is the final answer: concatenate its text blocks.
            if (json["stop_reason"] as? String) != "tool_use" {
                return Self.joinedText(from: content)
            }

            // Echo the assistant's tool_use turn back verbatim (required), then answer every tool_use
            // block with a matching tool_result in a single following user turn.
            wire.append(["role": "assistant", "content": content])
            var results: [[String: Any]] = []
            for block in content where (block["type"] as? String) == "tool_use" {
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let toolInput = block["input"] as? [String: Any] ?? [:]
                let output = await runTool(name, toolInput)
                results.append([
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": output
                ])
            }
            // A tool_use stop with no decodable blocks would loop forever — bail with the text we have.
            if results.isEmpty { return Self.joinedText(from: content) }
            wire.append(["role": "user", "content": results])
        }

        // Exhausted the round cap without a final answer: one last call WITHOUT tools forces text.
        return try await send(
            key: key, model: model, systemPrompt: systemPrompt,
            messages: Self.messagesForFinal(wire: wire),
            session: session
        )
    }

    /// Concatenate the `text` blocks of an Anthropic content array into one reply string.
    private static func joinedText(from content: [[String: Any]]) -> String {
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return text
    }

    /// Reduce the accumulated tool-use transcript to plain `(role, content)` turns for the tool-less
    /// final call. tool_use blocks are dropped, but every tool_result's CONTENT is carried over as text —
    /// the closing instruction says "using the data gathered above", so that data must actually be in the
    /// request. Assistant text produced between tool rounds is kept too. Static and pure — unit-tested.
    static func messagesForFinal(wire: [[String: Any]]) -> [(role: ChatMessage.Role, content: String)] {
        var out: [(role: ChatMessage.Role, content: String)] = []
        var gathered: [String] = []
        for turn in wire {
            guard let roleStr = turn["role"] as? String,
                  let role = ChatMessage.Role(rawValue: roleStr) else { continue }
            if let s = turn["content"] as? String {
                out.append((role, s))
            } else if let blocks = turn["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String, !t.isEmpty { out.append((role, t)) }
                    case "tool_result":
                        if let c = block["content"] as? String, !c.isEmpty { gathered.append(c) }
                    default:
                        break   // tool_use inputs carry nothing the final answer needs
                    }
                }
            }
        }
        var closing = "Answer now using the data gathered above. Do not request more tools."
        if !gathered.isEmpty {
            closing = "Data gathered by the tools so far:\n\n"
                + gathered.joined(separator: "\n\n")
                + "\n\n" + closing
        }
        out.append((.user, closing))
        // Dropping the tool_result turns can leave two same-role turns back to back; the API wants
        // alternation, so fold those into one.
        var merged: [(role: ChatMessage.Role, content: String)] = []
        for pair in out {
            if let last = merged.last, last.role == pair.role {
                merged[merged.count - 1].content += "\n\n" + pair.content
            } else {
                merged.append(pair)
            }
        }
        return merged
    }
}
