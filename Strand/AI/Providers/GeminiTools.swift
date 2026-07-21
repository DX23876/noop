import Foundation

/// Tool-calling and streaming for Google Gemini — the last provider stuck on the pre-baked context path,
/// unable to reach `propose_plan`, `remember_fact`, `plot_metric` or any of the other tools, and showing
/// nothing until the whole reply had arrived.
///
/// It was left out when the OpenAI-shaped providers got tools, for a stated reason: "own wire format, a
/// second test surface for one provider". That was a cost judgement, not an impossibility, and this is
/// the file that pays it. Kept separate from `Gemini.swift` (the upstream-shaped base client) so tracking
/// upstream never conflicts here.
///
/// Three things genuinely differ from the OpenAI shape, and each has bitten this integration:
///   • the SCHEMA is a subset — see `CoachTool.geminiSchema`; an unsupported keyword rejects the whole
///     request, so every tool disappears rather than one degrading;
///   • a tool result goes back as a `functionResponse` part whose `response` must be an OBJECT, so the
///     tool's plain-text output is wrapped rather than sent as a bare string;
///   • roles are `user` / `model` (never `assistant`), and the function-result turn rides as `user`.
extension GeminiClient: ToolCallingClient, StreamingToolClient {

    static var maxToolRounds: Int { 5 }   // mirrors AnthropicTools.maxToolRounds

    // MARK: - Non-streaming tool loop

    func sendWithTools(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        tools: [CoachTool],
        runTool: (String, [String: Any]) async -> String,
        session: URLSession
    ) async throws -> CoachToolReply {
        var contents = Self.contents(from: messages)
        var calledTools: [String] = []

        for _ in 0..<Self.maxToolRounds {
            let body = Self.requestBody(systemPrompt: systemPrompt, contents: contents, tools: tools)
            let json = try await performRequest(
                Self.request(key: key, model: model, body: body, streaming: false), session: session)
            let round = Self.parseCandidate(json)

            guard !round.calls.isEmpty else {
                return CoachToolReply(text: round.text, toolsUsed: calledTools)
            }
            contents.append(Self.modelTurn(for: round.calls))
            contents.append(await Self.functionResponseTurn(for: round.calls,
                                                            runTool: runTool,
                                                            called: &calledTools))
        }

        // Round cap hit mid-tool-use: force a tool-less answer that keeps the gathered data, the same
        // way the Anthropic and OpenAI loops do.
        let closing = try await performRequest(
            Self.request(key: key, model: model,
                         body: Self.requestBody(systemPrompt: systemPrompt,
                                                contents: Self.closingContents(from: contents),
                                                tools: []),
                         streaming: false),
            session: session)
        return CoachToolReply(text: Self.parseCandidate(closing).text, toolsUsed: calledTools)
    }

    // MARK: - Streaming tool loop

    func streamWithTools(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        tools: [CoachTool],
        runTool: (String, [String: Any]) async -> String,
        onDelta: @MainActor (String) -> Void,
        session: URLSession
    ) async throws -> CoachToolReply {
        var contents = Self.contents(from: messages)
        var calledTools: [String] = []
        var fullText = ""

        for _ in 0..<Self.maxToolRounds {
            let body = Self.requestBody(systemPrompt: systemPrompt, contents: contents, tools: tools)
            let round = try await streamRound(
                req: Self.request(key: key, model: model, body: body, streaming: true),
                session: session
            ) { delta in
                fullText += delta
                await onDelta(delta)
            }

            guard !round.calls.isEmpty else {
                return CoachToolReply(text: fullText, toolsUsed: calledTools)
            }
            contents.append(Self.modelTurn(for: round.calls))
            contents.append(await Self.functionResponseTurn(for: round.calls,
                                                            runTool: runTool,
                                                            called: &calledTools))
        }

        let closingBody = Self.requestBody(systemPrompt: systemPrompt,
                                           contents: Self.closingContents(from: contents), tools: [])
        _ = try await streamRound(
            req: Self.request(key: key, model: model, body: closingBody, streaming: true),
            session: session
        ) { delta in
            fullText += delta
            await onDelta(delta)
        }
        return CoachToolReply(text: fullText, toolsUsed: calledTools)
    }

    /// One streamed round over `:streamGenerateContent?alt=sse`. Gemini re-sends whole `candidates`
    /// objects per chunk rather than deltas of a single message, so text is taken per chunk and function
    /// calls are collected as they appear complete (they are never split across chunks the way OpenAI's
    /// argument strings are).
    private func streamRound(
        req: URLRequest,
        session: URLSession,
        onDelta: (String) async -> Void
    ) async throws -> (text: String, calls: [GeminiFunctionCall]) {
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AICoachError.network("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            switch http.statusCode {
            case 401, 403: throw AICoachError.badKey
            case 429: throw AICoachError.rateLimited
            default: throw AICoachError.server(http.statusCode,
                                               providerErrorMessage(from: Data(raw.utf8)))
            }
        }

        var text = ""
        var calls: [GeminiFunctionCall] = []
        var sawAnything = false

        for try await line in bytes.lines {
            guard let payload = OpenAIClient.ssePayload(line) else { continue }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            sawAnything = true
            let chunk = Self.parseCandidate(obj)
            if !chunk.text.isEmpty {
                text += chunk.text
                await onDelta(chunk.text)
            }
            calls.append(contentsOf: chunk.calls)
        }

        // Nothing decodable at all means the stream failed rather than finished. Unlike Anthropic's
        // `message_stop`, Gemini's SSE has no explicit terminator event to check for, so this is the
        // honest boundary: silence, not a partial reply, is what's detectable here.
        guard sawAnything else {
            throw AICoachError.network("The reply was cut off mid-stream — nothing arrived.")
        }
        return (text, calls)
    }

    // MARK: - Pure wire building (no network — unit-tested)

    /// Chat turns in Gemini's shape. Roles are `user` / `model`; there is no `assistant`.
    static func contents(from messages: [(role: ChatMessage.Role, content: String)]) -> [[String: Any]] {
        messages.map { m in
            ["role": m.role == .assistant ? "model" : "user", "parts": [["text": m.content]]]
        }
    }

    /// The request body. `maxOutputTokens` stays at Gemini's own 4096: it counts THINKING tokens against
    /// that cap, so the smaller visible-reply budget the other providers use starves a thinking model
    /// into an empty reply (see `Gemini.send`).
    static func requestBody(systemPrompt: String,
                            contents: [[String: Any]],
                            tools: [CoachTool]) -> [String: Any] {
        // `generationConfig` is annotated rather than left to inference: an un-annotated
        // `["temperature": 0.6, "maxOutputTokens": 4096]` infers as `[String: Double]`, quietly making
        // the token cap a Double. It serialises the same either way, but it reads as an Int and anything
        // inspecting it should find one.
        let generationConfig: [String: Any] = ["temperature": 0.6, "maxOutputTokens": 4096]
        var body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": generationConfig
        ]
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": tools.map { $0.geminiFunctionSpec }]]
        }
        return body
    }

    /// Built via `URL(string:)`, not `appendingPathComponent`: the latter percent-encodes the ":" in
    /// ":generateContent" on some Foundation versions and the API rejects `%3A` (same reason as
    /// `Gemini.send`).
    static func request(key: String, model: String,
                        body: [String: Any], streaming: Bool) -> URLRequest {
        let verb = streaming ? ":streamGenerateContent?alt=sse" : ":generateContent"
        let url = URL(string: "\(AIProvider.gemini.endpoint.absoluteString)/\(model)\(verb)")
        var req = URLRequest(url: url ?? AIProvider.gemini.endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Text and function calls out of one response (or one streamed chunk). Text can span several parts —
    /// a thinking model emits more than one — so they are joined rather than first-matched.
    static func parseCandidate(_ json: [String: Any]) -> (text: String, calls: [GeminiFunctionCall]) {
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return ("", [])
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        let calls: [GeminiFunctionCall] = parts.compactMap { part in
            guard let fn = part["functionCall"] as? [String: Any],
                  let name = fn["name"] as? String, !name.isEmpty else { return nil }
            return GeminiFunctionCall(name: name, args: fn["args"] as? [String: Any] ?? [:])
        }
        return (text, calls)
    }

    /// The model turn echoing its own function calls — required before the matching results.
    static func modelTurn(for calls: [GeminiFunctionCall]) -> [String: Any] {
        ["role": "model",
         "parts": calls.map { ["functionCall": ["name": $0.name, "args": $0.args]] }]
    }

    /// Run each call and pack the results into one turn. `response` MUST be an object here, so the
    /// tool's plain text is wrapped in `{"result": …}` rather than sent bare — a bare string is rejected.
    /// The turn's role is `user`: Gemini has no separate tool role in the REST shape.
    static func functionResponseTurn(for calls: [GeminiFunctionCall],
                                     runTool: (String, [String: Any]) async -> String,
                                     called: inout [String]) async -> [String: Any] {
        var parts: [[String: Any]] = []
        for call in calls {
            let output = await runTool(call.name, call.args)
            called.append(call.name)
            parts.append(["functionResponse": ["name": call.name, "response": ["result": output]]])
        }
        return ["role": "user", "parts": parts]
    }

    /// Reduce an accumulated tool transcript to a tool-less closing request, folding the gathered results
    /// into a final user turn instead of discarding them — the Gemini twin of `closingWire`. Without it
    /// the closing instruction ("using the data gathered above") would be a lie.
    static func closingContents(from contents: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var gathered: [String] = []
        for turn in contents {
            let parts = turn["parts"] as? [[String: Any]] ?? []
            for part in parts {
                if let fr = part["functionResponse"] as? [String: Any],
                   let response = fr["response"] as? [String: Any],
                   let result = response["result"] as? String, !result.isEmpty {
                    gathered.append(result)
                }
            }
            let texts = parts.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
            if !texts.isEmpty {
                out.append(["role": turn["role"] ?? "user", "parts": texts.map { ["text": $0] }])
            }
        }
        var closing = "Answer now using the data gathered above. Do not request more tools."
        if !gathered.isEmpty {
            closing = "Data gathered by the tools so far:\n\n" + gathered.joined(separator: "\n\n")
                + "\n\n" + closing
        }
        out.append(["role": "user", "parts": [["text": closing]]])
        return out
    }
}

/// One function call Gemini asked for. Unlike the OpenAI shape, `args` arrives as a decoded object, not
/// a JSON string split across chunks — nothing to reassemble.
struct GeminiFunctionCall: Equatable {
    let name: String
    let args: [String: Any]

    static func == (lhs: GeminiFunctionCall, rhs: GeminiFunctionCall) -> Bool {
        lhs.name == rhs.name && NSDictionary(dictionary: lhs.args).isEqual(to: rhs.args)
    }
}
