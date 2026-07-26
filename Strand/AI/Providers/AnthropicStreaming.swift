import Foundation

/// Streaming tool-use loop for Anthropic's Messages API (SSE). Kept separate from `AnthropicClient`'s
/// base file so it merges cleanly against upstream. Each round opens a streamed request; text deltas are
/// forwarded to `onDelta` the instant they arrive, while `tool_use` blocks are reassembled from their
/// `input_json_delta` fragments so the loop can run tools and continue — exactly like the non-streaming
/// `sendWithTools`, just live.
extension AnthropicClient: StreamingToolClient {

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
        var wire: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let toolSpecs = tools.map { $0.anthropicSpec }
        var fullText = ""
        // The evidence chain (P6): every tool name actually called, in call order, across every round.
        var calledTools: [String] = []
        await Self.beginUsageTurn()

        for _ in 0..<Self.maxToolRounds {
            // `system` rides as a cacheable block array: tools + prompt are re-sent on every round below,
            // so caching that pair is what keeps a multi-round answer from paying for them each time.
            var body: [String: Any] = [
                "model": model,
                "max_tokens": CoachOutputBudget.maxTokens,
                "system": Self.cacheableSystem(systemPrompt),
                "messages": wire,
                "stream": true
            ]
            if !toolSpecs.isEmpty { body["tools"] = toolSpecs }

            var req = URLRequest(url: AIProvider.anthropic.endpoint)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let round = try await streamRound(req: req, session: session) { delta in
                fullText += delta
                await onDelta(delta)
            }
            await Self.recordUsage(round.usage)

            // A tool request → echo the assistant turn, answer every tool_use block, loop.
            if round.stopReason == "tool_use" {
                wire.append(["role": "assistant", "content": round.content])
                var results: [[String: Any]] = []
                for block in round.content where (block["type"] as? String) == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    let output = await runTool(name, input)
                    calledTools.append(name)
                    results.append(["type": "tool_result", "tool_use_id": id, "content": output])
                }
                if results.isEmpty { return CoachToolReply(text: fullText, toolsUsed: calledTools) }
                wire.append(["role": "user", "content": results])
                continue
            }

            return CoachToolReply(text: fullText, toolsUsed: calledTools)
        }

        // Exhausted the round cap mid-tool-use. The non-streaming loop forces a tool-less closing call
        // here; without it the user gets whatever half-round text accumulated — possibly nothing. The
        // closing reply doesn't stream, so it is forwarded through `onDelta` to reach the live bubble.
        let closing = try await send(
            key: key, model: model, systemPrompt: systemPrompt,
            messages: Self.messagesForFinal(wire: wire),
            session: session
        )
        let trimmed = closing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let sep = fullText.isEmpty ? "" : "\n\n"
            await onDelta(sep + trimmed)
            fullText += sep + trimmed
        }
        return CoachToolReply(text: fullText, toolsUsed: calledTools)
    }

    /// The outcome of one streamed round: the reassembled content blocks (text + tool_use with parsed
    /// input), the stop reason, and the round's token counts. `onDelta` is invoked for each text fragment
    /// as it streams in.
    private struct StreamedRound {
        var stopReason: String?
        var content: [[String: Any]]
        var usage: CoachUsageLog.Round = .init()
    }

    private func streamRound(
        req: URLRequest,
        session: URLSession,
        onDelta: (String) async -> Void
    ) async throws -> StreamedRound {
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw AICoachError.network("no HTTP response") }
        guard (200...299).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403: throw AICoachError.badKey
            case 429: throw AICoachError.rateLimited(retryAfter: retryAfterSeconds(http))
            default: throw AICoachError.server(http.statusCode, "")
            }
        }

        // Content blocks accumulated by their stream index. Text builds in "text"; a tool_use block's
        // JSON input arrives as fragments in "__json" and is parsed into "input" at content_block_stop.
        var blocks: [Int: [String: Any]] = [:]
        var stopReason: String?
        // Set on `message_stop` — the only reliable end-of-stream signal. A byte stream that just ends
        // without it was cut off (network drop, proxy timeout), not completed.
        var sawMessageStop = false
        // Token counts arrive split across two events: the input/cache side on `message_start`, the
        // output side on `message_delta`.
        var usage = CoachUsageLog.Round()

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }   // ignore "event:" lines, blanks, pings
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                guard let index = obj["index"] as? Int,
                      let cb = obj["content_block"] as? [String: Any] else { break }
                if (cb["type"] as? String) == "tool_use" {
                    blocks[index] = ["type": "tool_use", "id": cb["id"] ?? "", "name": cb["name"] ?? "", "__json": ""]
                } else {
                    blocks[index] = ["type": "text", "text": ""]
                }

            case "content_block_delta":
                guard let index = obj["index"] as? Int,
                      let delta = obj["delta"] as? [String: Any] else { break }
                switch delta["type"] as? String {
                case "text_delta":
                    if let t = delta["text"] as? String {
                        let existing = (blocks[index]?["text"] as? String) ?? ""
                        blocks[index] = ["type": "text", "text": existing + t]
                        await onDelta(t)
                    }
                case "input_json_delta":
                    if let pj = delta["partial_json"] as? String {
                        let existing = (blocks[index]?["__json"] as? String) ?? ""
                        var b = blocks[index] ?? ["type": "tool_use"]
                        b["__json"] = existing + pj
                        blocks[index] = b
                    }
                default:
                    break
                }

            case "content_block_stop":
                if let index = obj["index"] as? Int,
                   (blocks[index]?["type"] as? String) == "tool_use" {
                    let jsonStr = (blocks[index]?["__json"] as? String) ?? "{}"
                    let input = (try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8))) as? [String: Any] ?? [:]
                    blocks[index]?["input"] = input
                    blocks[index]?["__json"] = nil
                }

            case "message_start":
                // Carries this round's input, cache-read and cache-write counts — the only place the
                // cache's effect is observable.
                if let message = obj["message"] as? [String: Any],
                   let u = message["usage"] as? [String: Any] {
                    let parsed = Self.parseUsage(u)
                    usage.inputTokens = parsed.inputTokens
                    usage.cacheReadTokens = parsed.cacheReadTokens
                    usage.cacheWriteTokens = parsed.cacheWriteTokens
                }

            case "message_delta":
                if let delta = obj["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String {
                    stopReason = sr
                }
                if let u = obj["usage"] as? [String: Any] {
                    usage.outputTokens = Self.parseUsage(u).outputTokens
                }

            case "message_stop":
                sawMessageStop = true

            default:
                break   // ping, content_block_stop for text, etc.
            }
        }

        // The stream ended without `message_stop`: the connection was cut mid-reply. Surfacing this
        // matters because the partial text already streamed into the UI and would otherwise pass as a
        // complete (short) answer. A user-initiated Stop never reaches here — cancellation throws out
        // of the `for try await` above.
        guard sawMessageStop else {
            throw AICoachError.network("The reply was cut off mid-stream — what streamed so far may be incomplete.")
        }

        // Order blocks by their stream index and strip the transient JSON-accumulator key.
        let ordered: [[String: Any]] = blocks.keys.sorted().compactMap { idx in
            guard var b = blocks[idx] else { return nil }
            b.removeValue(forKey: "__json")
            return b
        }
        return StreamedRound(stopReason: stopReason, content: ordered, usage: usage)
    }
}
