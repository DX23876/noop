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
    ) async throws -> String {
        var wire: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let toolSpecs = tools.map { $0.anthropicSpec }
        var fullText = ""

        for _ in 0..<Self.maxToolRounds {
            var body: [String: Any] = [
                "model": model,
                "max_tokens": 1200,
                "system": systemPrompt,
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

            // A tool request → echo the assistant turn, answer every tool_use block, loop.
            if round.stopReason == "tool_use" {
                wire.append(["role": "assistant", "content": round.content])
                var results: [[String: Any]] = []
                for block in round.content where (block["type"] as? String) == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    let output = await runTool(name, input)
                    results.append(["type": "tool_result", "tool_use_id": id, "content": output])
                }
                if results.isEmpty { return fullText }
                wire.append(["role": "user", "content": results])
                continue
            }

            return fullText
        }

        return fullText
    }

    /// The outcome of one streamed round: the reassembled content blocks (text + tool_use with parsed
    /// input) and the stop reason. `onDelta` is invoked for each text fragment as it streams in.
    private struct StreamedRound { var stopReason: String?; var content: [[String: Any]] }

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
            case 429: throw AICoachError.rateLimited
            default: throw AICoachError.server(http.statusCode, "")
            }
        }

        // Content blocks accumulated by their stream index. Text builds in "text"; a tool_use block's
        // JSON input arrives as fragments in "__json" and is parsed into "input" at content_block_stop.
        var blocks: [Int: [String: Any]] = [:]
        var stopReason: String?

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

            case "message_delta":
                if let delta = obj["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String {
                    stopReason = sr
                }

            default:
                break   // message_start, ping, content_block_stop for text, message_stop, etc.
            }
        }

        // Order blocks by their stream index and strip the transient JSON-accumulator key.
        let ordered: [[String: Any]] = blocks.keys.sorted().compactMap { idx in
            guard var b = blocks[idx] else { return nil }
            b.removeValue(forKey: "__json")
            return b
        }
        return StreamedRound(stopReason: stopReason, content: ordered)
    }
}
