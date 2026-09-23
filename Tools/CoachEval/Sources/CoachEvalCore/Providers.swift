import Foundation
import CoachAnalysis

/// What one question cost and produced.
public struct Transcript: Codable, Sendable {
    public var answer = ""
    public var inputTokens = 0
    public var outputTokens = 0
    public var toolCalls = 0
    /// Calls the tool refused (ANALYSIS NOT RUN) — the model then has to repair its spec.
    public var invalidCalls = 0
    public var rounds = 0
}

/// A model behind one provider's tool-calling API. Minimal on purpose: the evaluation measures what a model
/// does with `run_analysis`, so these loops carry no retries of their own beyond transient HTTP errors.
public protocol EvalProvider {
    var name: String { get }
    var model: String { get }
    func run(system: String, question: String, dataset: AnalysisDataset,
             handle: ([String: Any]) -> String) async throws -> Transcript
}

public enum ProviderError: Error, CustomStringConvertible {
    case missingKey(String)
    case http(Int, String)
    case malformed(String)

    public var description: String {
        switch self {
        case .missingKey(let env): return "no API key: set \(env)"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
        case .malformed(let what): return "unexpected response: \(what)"
        }
    }
}

public enum Providers {
    /// The most tool rounds a question may take — the app's own limit.
    public static let maxRounds = 6

    public static func make(_ name: String, model: String) throws -> EvalProvider {
        let env = ProcessInfo.processInfo.environment
        switch name {
        case "anthropic":
            guard let key = env["ANTHROPIC_API_KEY"] else { throw ProviderError.missingKey("ANTHROPIC_API_KEY") }
            return AnthropicEval(key: key, model: model)
        case "openai":
            guard let key = env["OPENAI_API_KEY"] else { throw ProviderError.missingKey("OPENAI_API_KEY") }
            return OpenAIEval(key: key, model: model)
        case "gemini":
            guard let key = env["GEMINI_API_KEY"] ?? env["GOOGLE_API_KEY"] else {
                throw ProviderError.missingKey("GEMINI_API_KEY")
            }
            return GeminiEval(key: key, model: model)
        default:
            throw ProviderError.malformed("unknown provider \(name) (anthropic, openai, gemini)")
        }
    }

    static func post(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var delay: UInt64 = 2_000_000_000
        for attempt in 1...4 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500, attempt < 4 {
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
                continue
            }
            guard (200..<300).contains(status) else {
                throw ProviderError.http(status, String(data: data, encoding: .utf8) ?? "")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderError.malformed("not a JSON object")
            }
            return json
        }
        throw ProviderError.malformed("retries exhausted")
    }

    static func record(_ output: String, into transcript: inout Transcript) {
        transcript.toolCalls += 1
        if output.hasPrefix("ANALYSIS NOT RUN") { transcript.invalidCalls += 1 }
    }
}

struct AnthropicEval: EvalProvider {
    let key: String
    let model: String
    var name: String { "anthropic" }

    func run(system: String, question: String, dataset: AnalysisDataset,
             handle: ([String: Any]) -> String) async throws -> Transcript {
        var transcript = Transcript()
        var messages: [[String: Any]] = [["role": "user", "content": question]]
        let tools: [[String: Any]] = [[
            "name": AnalysisToolSchema.name, "description": AnalysisToolSchema.description,
            "input_schema": AnalysisToolSchema.inputSchema(for: dataset),
        ]]
        for _ in 0..<Providers.maxRounds {
            transcript.rounds += 1
            let json = try await Providers.post(
                URL(string: "https://api.anthropic.com/v1/messages")!,
                headers: ["x-api-key": key, "anthropic-version": "2023-06-01"],
                body: ["model": model, "max_tokens": 2_048, "system": system, "tools": tools, "messages": messages])
            if let usage = json["usage"] as? [String: Any] {
                transcript.inputTokens += (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                transcript.outputTokens += usage["output_tokens"] as? Int ?? 0
            }
            guard let content = json["content"] as? [[String: Any]] else { throw ProviderError.malformed("no content") }
            transcript.answer = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            let uses = content.filter { $0["type"] as? String == "tool_use" }
            guard !uses.isEmpty else { break }
            messages.append(["role": "assistant", "content": content])
            let results: [[String: Any]] = uses.map { use in
                let output = handle(use["input"] as? [String: Any] ?? [:])
                Providers.record(output, into: &transcript)
                return ["type": "tool_result", "tool_use_id": use["id"] as? String ?? "", "content": output]
            }
            messages.append(["role": "user", "content": results])
        }
        return transcript
    }
}

struct OpenAIEval: EvalProvider {
    let key: String
    let model: String
    var name: String { "openai" }

    func run(system: String, question: String, dataset: AnalysisDataset,
             handle: ([String: Any]) -> String) async throws -> Transcript {
        var transcript = Transcript()
        var messages: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": question]]
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": ["name": AnalysisToolSchema.name, "description": AnalysisToolSchema.description,
                         "parameters": AnalysisToolSchema.inputSchema(for: dataset)],
        ]]
        for _ in 0..<Providers.maxRounds {
            transcript.rounds += 1
            let json = try await Providers.post(
                URL(string: "https://api.openai.com/v1/chat/completions")!,
                headers: ["Authorization": "Bearer \(key)"],
                body: ["model": model, "messages": messages, "tools": tools, "max_completion_tokens": 4_096])
            if let usage = json["usage"] as? [String: Any] {
                transcript.inputTokens += usage["prompt_tokens"] as? Int ?? 0
                transcript.outputTokens += usage["completion_tokens"] as? Int ?? 0
            }
            guard let message = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else {
                throw ProviderError.malformed("no message")
            }
            transcript.answer = message["content"] as? String ?? ""
            guard let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty else { break }
            messages.append(message)
            for call in calls {
                let function = call["function"] as? [String: Any] ?? [:]
                let arguments = (function["arguments"] as? String).flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
                let output = handle(arguments)
                Providers.record(output, into: &transcript)
                messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": output])
            }
        }
        return transcript
    }
}

struct GeminiEval: EvalProvider {
    let key: String
    let model: String
    var name: String { "gemini" }

    func run(system: String, question: String, dataset: AnalysisDataset,
             handle: ([String: Any]) -> String) async throws -> Transcript {
        var transcript = Transcript()
        var contents: [[String: Any]] = [["role": "user", "parts": [["text": question]]]]
        let tools: [[String: Any]] = [["functionDeclarations": [[
            "name": AnalysisToolSchema.name, "description": AnalysisToolSchema.description,
            "parameters": AnalysisToolSchema.inputSchema(for: dataset),
        ]]]]
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        for _ in 0..<Providers.maxRounds {
            transcript.rounds += 1
            let json = try await Providers.post(url, headers: ["x-goog-api-key": key], body: [
                "system_instruction": ["parts": [["text": system]]],
                "contents": contents, "tools": tools,
                "generationConfig": ["maxOutputTokens": 8_192] as [String: Any],
            ])
            if let usage = json["usageMetadata"] as? [String: Any] {
                transcript.inputTokens += usage["promptTokenCount"] as? Int ?? 0
                transcript.outputTokens += (usage["candidatesTokenCount"] as? Int ?? 0) + (usage["thoughtsTokenCount"] as? Int ?? 0)
            }
            guard let content = ((json["candidates"] as? [[String: Any]])?.first)?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { throw ProviderError.malformed("no candidate") }
            transcript.answer = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
            guard !calls.isEmpty else { break }
            // The model turn goes back verbatim: Gemini 3 requires each call's thought signature echoed.
            contents.append(content)
            let responses: [[String: Any]] = calls.map { call in
                let output = handle(call["args"] as? [String: Any] ?? [:])
                Providers.record(output, into: &transcript)
                return ["functionResponse": ["name": call["name"] as? String ?? "", "response": ["result": output]]]
            }
            contents.append(["role": "user", "parts": responses])
        }
        return transcript
    }
}
