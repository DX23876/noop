import Foundation

/// Token-by-token streaming for the OpenAI-shaped providers — OpenAI, OpenRouter and Custom.
///
/// Until now only Anthropic conformed to `StreamingToolClient`, so everyone else waited on a spinner for
/// the whole reply. That is worst exactly where it hurts most: `Custom` points at a local server
/// (Ollama, LM Studio, llama.cpp) generating at a handful of tokens a second, where a full answer can
/// take minutes and, without streaming, shows nothing at all until it is finished. The engine already
/// casts generically (`provider.client as? StreamingToolClient`), so conforming here is all that's
/// needed — no engine change.
///
/// Why this is a separate protocol from `OpenAICompatibleToolClient` rather than an extension of it:
/// **Custom streams but deliberately does not get tools.** That exclusion is a real decision, not an
/// oversight — tool support on a local server depends on both the server and the model, and many local
/// models fail silently or emit malformed JSON instead of a clean error. Streaming carries no such risk:
/// a server that ignores `stream: true` simply returns one chunk. Binding the two protocols together
/// would have forced Custom to take tools to get streaming.
///
/// Mirrors `AnthropicStreaming.swift`: same round cap, same tool loop, same forcing final call when the
/// cap is hit, and the same refusal to let a cut-off stream pass as a complete answer.
/// A tool call reassembled from its streamed fragments. `arguments` arrives as a JSON *string* split
/// across chunks, so it is accumulated as text and decoded only once the round ends. File scope rather
/// than nested in the protocol extension below — Swift doesn't allow types nested there.
struct StreamedToolCall: Equatable {
    var id: String
    var name: String
    var arguments: String
}

/// The outcome of one streamed round: the text that accumulated (already forwarded delta by delta), any
/// tool calls the model requested, and why the round ended.
struct StreamedRound {
    var text: String = ""
    var toolCalls: [StreamedToolCall] = []
    var finishReason: String?
    /// Whether the model emitted REASONING tokens this round (OpenRouter's `delta.reasoning`, some
    /// gateways' `delta.reasoning_content`). Not the reasoning text — that is deliberately never shown as
    /// the answer — only that thinking happened, which is what makes an empty reply explicable.
    var sawReasoning = false
    /// Token counts, when the provider sent a usage chunk.
    var usage: CoachUsageLog.Round?
}

protocol OpenAICompatibleStreamingClient: StreamingToolClient {
    var streamChatEndpoint: URL { get }
    func authorizeStreamRequest(_ req: inout URLRequest, key: String)
    /// Runs before any egress. Custom uses it for the #321 cleartext-base-URL guard; the fixed-URL
    /// providers have nothing to check.
    func preflightStream() throws
    /// Appended when the server reports it stopped at a length limit, so a cutoff is never silent.
    /// Custom supplies the Ollama-vs-gateway advice its non-streaming path already gives; nil elsewhere.
    func lengthCutoffNote() -> String?
}

extension OpenAICompatibleStreamingClient {
    func preflightStream() throws {}
    func lengthCutoffNote() -> String? { nil }
}

extension OpenAIClient: OpenAICompatibleStreamingClient {
    var streamChatEndpoint: URL { AIProvider.openAI.endpoint }
    func authorizeStreamRequest(_ req: inout URLRequest, key: String) {
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
}

extension OpenRouterClient: OpenAICompatibleStreamingClient {
    var streamChatEndpoint: URL { AIProvider.openRouter.endpoint }
    func authorizeStreamRequest(_ req: inout URLRequest, key: String) {
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
}

extension CustomClient: OpenAICompatibleStreamingClient {
    var streamChatEndpoint: URL { AIProvider.custom.endpoint }
    /// A local server usually needs no key, so the header is sent only when one is set — same rule as
    /// `CustomClient.chat`.
    func authorizeStreamRequest(_ req: inout URLRequest, key: String) {
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    }
    func preflightStream() throws { try AIProvider.guardCustomBaseURL() }
    func lengthCutoffNote() -> String? {
        CustomClient.truncationNote(isLocalServer: CustomClient.isLocalCustomServer)
    }
}

extension OpenAICompatibleStreamingClient {

    static var maxStreamToolRounds: Int { 5 }   // mirrors AnthropicTools.maxToolRounds

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
        try preflightStream()

        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }
        let toolSpecs = tools.map { $0.openAIFunctionSpec }
        var fullText = ""
        var calledTools: [String] = []
        // Decided at most once per conversation: if round 1 needs the modern param shape, so will every
        // later round (same model, same server) — mirrors the non-streaming tool loop.
        var modernParams = false
        // Token accounting was Anthropic-only, so OpenRouter and OpenAI users had no idea what a turn
        // cost. That gap matters most exactly here, where the user picks the model (and its price).
        await CoachUsageLog.beginTurnFromProvider()

        for _ in 0..<Self.maxStreamToolRounds {
            let round = try await streamRound(
                key: key, model: model, wire: wire, tools: toolSpecs,
                modernParams: &modernParams, session: session
            ) { delta in
                fullText += delta
                await onDelta(delta)
            }
            if let usage = round.usage { await CoachUsageLog.recordFromProvider(usage) }

            guard !round.toolCalls.isEmpty else {
                // A length cutoff must not pass as a finished answer (Custom's non-streaming path warns
                // about this too; streaming would otherwise silently lose that warning).
                if round.finishReason == "length", let note = lengthCutoffNote() {
                    await onDelta(note)
                    fullText += note
                }
                // Thought, but never spoke: a reasoning model can burn the entire output budget on
                // thinking before the first visible word (the documented Gemini 2.5 Pro incident behind
                // `CoachOutputBudget`). The user would otherwise see "(no reply)" for a request they
                // paid for, with nothing to act on. Say what happened instead.
                if fullText.isEmpty, round.sawReasoning {
                    let note = Self.reasoningWithoutAnswerNote
                    await onDelta(note)
                    fullText += note
                }
                return CoachToolReply(text: fullText, toolsUsed: calledTools)
            }

            // Echo the assistant's tool-call turn exactly, then answer each call — the API requires that
            // turn to precede its matching tool results.
            wire.append(Self.assistantToolCallTurn(text: round.text, calls: round.toolCalls))
            for call in round.toolCalls {
                let input = Self.decodeArguments(call.arguments)
                let output = await runTool(call.name, input)
                calledTools.append(call.name)
                wire.append(["role": "tool", "tool_call_id": call.id, "content": output])
            }
        }

        // Cap exhausted mid-tool-use: force a tool-less closing answer that keeps the gathered data,
        // reusing the SAME reduction the non-streaming loop uses (`closingWire`), so the two can't drift
        // on what "answer using the data gathered above" is allowed to mean. Its text streams like any
        // other round, so the return value carries nothing `fullText` doesn't already hold.
        _ = try await streamRound(
            key: key, model: model, wire: OpenAIClient.closingWire(from: wire), tools: [],
            modernParams: &modernParams, session: session
        ) { delta in
            fullText += delta
            await onDelta(delta)
        }
        return CoachToolReply(text: fullText, toolsUsed: calledTools)
    }

    // MARK: - One streamed round

    private func streamRound(
        key: String, model: String, wire: [[String: Any]], tools: [[String: Any]],
        modernParams: inout Bool, session: URLSession,
        onDelta: (String) async -> Void
    ) async throws -> StreamedRound {
        do {
            return try await openStream(key: key, model: model, wire: wire, tools: tools,
                                        modernParams: modernParams, session: session, onDelta: onDelta)
        } catch let AICoachError.server(code, detail) where code == 400 && !modernParams {
            // The same reasoning-model param retry the non-streaming paths do. Safe to retry: a 400 is
            // rejected before any token streams, so nothing has reached the UI yet.
            let d = detail.lowercased()
            guard d.contains("max_completion_tokens") || d.contains("max_tokens")
                || d.contains("temperature") || d.contains("unsupported") else {
                throw AICoachError.server(code, detail)
            }
            modernParams = true
            return try await openStream(key: key, model: model, wire: wire, tools: tools,
                                        modernParams: true, session: session, onDelta: onDelta)
        }
    }

    private func openStream(
        key: String, model: String, wire: [[String: Any]], tools: [[String: Any]],
        modernParams: Bool, session: URLSession,
        onDelta: (String) async -> Void
    ) async throws -> StreamedRound {
        var body: [String: Any] = ["model": model, "messages": wire, "stream": true]
        // Without this a streamed response reports no token counts at all — the usage arrives only in a
        // final extra chunk, and only when asked for. A server that doesn't know the option ignores it.
        body["stream_options"] = ["include_usage": true]
        if !tools.isEmpty { body["tools"] = tools }
        if modernParams {
            body["max_completion_tokens"] = CoachOutputBudget.maxTokens
        } else {
            body["temperature"] = 0.6
            body["max_tokens"] = CoachOutputBudget.maxTokens
        }

        var req = URLRequest(url: streamChatEndpoint)
        req.httpMethod = "POST"
        authorizeStreamRequest(&req, key: key)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AICoachError.network("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            // An error body on a streamed request still arrives as bytes; read it so a 400 carries the
            // detail the param retry above matches on, instead of an empty string it can never match.
            var raw = ""
            for try await line in bytes.lines { raw += line }
            switch http.statusCode {
            case 401, 403: throw AICoachError.badKey
            case 429: throw AICoachError.rateLimited(retryAfter: retryAfterSeconds(http))
            default: throw AICoachError.server(http.statusCode,
                                               providerErrorMessage(from: Data(raw.utf8)))
            }
        }

        var round = StreamedRound()
        var partial: [Int: StreamedToolCall] = [:]
        var sawTerminator = false

        for try await line in bytes.lines {
            guard let payload = Self.ssePayload(line) else { continue }
            if payload == "[DONE]" { sawTerminator = true; break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let chunk = Self.parseChunk(obj)
            if let text = chunk.text, !text.isEmpty {
                round.text += text
                await onDelta(text)
            }
            // Reasoning is tracked but NOT streamed into the answer: it is the model's scratch work, it
            // is often long, and presenting it as coaching would be misleading. The transcript stays the
            // answer; the running "Coach is thinking…" indicator already covers the wait.
            if chunk.sawReasoning { round.sawReasoning = true }
            for delta in chunk.toolCallDeltas {
                Self.merge(delta, into: &partial)
            }
            if let usage = chunk.usage { round.usage = usage }
            if let reason = chunk.finishReason {
                round.finishReason = reason
                sawTerminator = true
            }
        }

        // No `[DONE]` and no finish_reason: the connection was cut mid-reply. This matters because the
        // partial text has already streamed into the UI and would otherwise read as a complete, short
        // answer. A user-initiated Stop never lands here — cancellation throws out of the loop above.
        guard sawTerminator else {
            throw AICoachError.network("The reply was cut off mid-stream — what streamed so far may be "
                                       + "incomplete.")
        }

        round.toolCalls = partial.keys.sorted().compactMap { partial[$0] }
            .filter { !$0.name.isEmpty }
        return round
    }

    // MARK: - Pure (no network — unit-tested)

    /// The payload of one SSE line, or nil for the blanks, comments and `event:` lines around it.
    static func ssePayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        return payload.isEmpty ? nil : payload
    }

    /// One streamed chunk decomposed into what the loop needs. Everything is optional: a chunk may carry
    /// text, tool-call fragments, a finish reason, usage, or nothing at all (keep-alives).
    ///
    /// `usage` arrives in its OWN final chunk that carries no choices — which is why the choices guard
    /// can't come first, as it did before: it would have discarded every token count.
    static func parseChunk(_ obj: [String: Any])
        -> (text: String?, toolCallDeltas: [[String: Any]], finishReason: String?,
            sawReasoning: Bool, usage: CoachUsageLog.Round?) {
        let usage = (obj["usage"] as? [String: Any]).map(parseOpenAIUsage)
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else {
            return (nil, [], nil, false, usage)
        }
        let delta = first["delta"] as? [String: Any] ?? [:]
        // Two spellings in the wild: OpenRouter normalises to `reasoning`, several gateways passing
        // through DeepSeek-style models emit `reasoning_content`. Either counts as "it thought".
        let reasoning = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String)
        return (delta["content"] as? String,
                delta["tool_calls"] as? [[String: Any]] ?? [],
                first["finish_reason"] as? String,
                !(reasoning ?? "").isEmpty,
                usage)
    }

    /// Token counts from an OpenAI-shaped `usage` object. `prompt_tokens` INCLUDES cached tokens, so the
    /// cached part is subtracted out to match Anthropic's split, where `input_tokens` excludes them —
    /// otherwise the same turn would report a different total depending on the provider.
    static func parseOpenAIUsage(_ usage: [String: Any]) -> CoachUsageLog.Round {
        let prompt = usage["prompt_tokens"] as? Int ?? 0
        let cached = ((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int) ?? 0
        return CoachUsageLog.Round(
            inputTokens: max(0, prompt - cached),
            cacheReadTokens: cached,
            cacheWriteTokens: 0,   // no OpenAI-shaped provider reports a separate cache-WRITE count
            outputTokens: usage["completion_tokens"] as? Int ?? 0
        )
    }

    /// Shown when a round produced reasoning but no visible answer — see the call site for why a bare
    /// "(no reply)" is the wrong outcome there.
    static var reasoningWithoutAnswerNote: String {
        "*The model spent its whole reply budget on internal reasoning and never got to an answer. "
            + "Ask something narrower, or pick a model that reasons less.*"
    }

    /// Fold one `tool_calls` delta into the accumulator. Only the FIRST chunk of a call carries `id` and
    /// `function.name`; later ones carry `arguments` fragments alone, keyed by `index`. Appending
    /// unconditionally would therefore blank the name on the second chunk.
    static func merge(_ delta: [String: Any], into partial: inout [Int: StreamedToolCall]) {
        let index = (delta["index"] as? Int) ?? 0
        var call = partial[index] ?? StreamedToolCall(id: "", name: "", arguments: "")
        if let id = delta["id"] as? String, !id.isEmpty { call.id = id }
        if let fn = delta["function"] as? [String: Any] {
            if let name = fn["name"] as? String, !name.isEmpty { call.name = name }
            if let args = fn["arguments"] as? String { call.arguments += args }
        }
        partial[index] = call
    }

    /// Decode an accumulated `arguments` string. A model that streamed malformed JSON yields an empty
    /// input rather than throwing — the tool then reports what it needs, which is recoverable, whereas
    /// aborting the whole reply is not.
    static func decodeArguments(_ raw: String) -> [String: Any] {
        guard !raw.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    /// The assistant turn echoing this round's tool calls, in the shape the API requires back.
    /// `content` is `NSNull` rather than "" when the model emitted no text alongside the calls: the
    /// OpenAI schema expects null there, and some gateways reject an empty string.
    static func assistantToolCallTurn(text: String, calls: [StreamedToolCall]) -> [String: Any] {
        [
            "role": "assistant",
            "content": text.isEmpty ? NSNull() : text,
            "tool_calls": calls.map { call in
                ["id": call.id, "type": "function",
                 "function": ["name": call.name, "arguments": call.arguments]] as [String: Any]
            }
        ]
    }
}
