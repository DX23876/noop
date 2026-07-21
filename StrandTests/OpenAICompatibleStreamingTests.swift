import XCTest
@testable import Strand

/// SSE parsing for the OpenAI-shaped providers. Only Anthropic streamed before, so OpenAI, OpenRouter
/// and Custom users waited on a spinner for the whole reply — worst on a local Ollama model generating
/// at a few tokens a second, where nothing appeared for minutes.
///
/// The pure parsing is what's testable without a network, and it is also where this format is genuinely
/// tricky: a tool call is split across chunks, and only the FIRST one carries `id` and `function.name`.
/// Reassembling that wrong silently produces a nameless call, i.e. a tool that never runs.
@MainActor
final class OpenAICompatibleStreamingTests: XCTestCase {

    private let client = OpenAIClient()

    private func chunk(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: - SSE framing

    func testDataLineIsUnwrapped() {
        XCTAssertEqual(OpenAIClient.ssePayload("data: {\"a\":1}"), "{\"a\":1}")
    }

    func testTerminatorIsSurfacedVerbatim() {
        XCTAssertEqual(OpenAIClient.ssePayload("data: [DONE]"), "[DONE]",
                       "the loop breaks on this exact token")
    }

    func testNonDataLinesAreIgnored() {
        XCTAssertNil(OpenAIClient.ssePayload(""))
        XCTAssertNil(OpenAIClient.ssePayload(": keep-alive"))
        XCTAssertNil(OpenAIClient.ssePayload("event: message"))
        XCTAssertNil(OpenAIClient.ssePayload("data:"), "an empty payload carries nothing to parse")
    }

    // MARK: - Chunk decomposition

    func testTextDeltaIsExtracted() {
        let parsed = OpenAIClient.parseChunk(chunk("""
        {"choices":[{"delta":{"content":"Hallo"},"finish_reason":null}]}
        """))
        XCTAssertEqual(parsed.text, "Hallo")
        XCTAssertNil(parsed.finishReason)
    }

    func testFinishReasonIsExtracted() {
        let parsed = OpenAIClient.parseChunk(chunk("""
        {"choices":[{"delta":{},"finish_reason":"stop"}]}
        """))
        XCTAssertEqual(parsed.finishReason, "stop")
    }

    /// Usage-only and keep-alive chunks carry no choices at all. Returning nils rather than throwing is
    /// what keeps a stream alive across them.
    func testChunkWithoutChoicesIsInert() {
        let parsed = OpenAIClient.parseChunk(chunk("""
        {"usage":{"total_tokens":42}}
        """))
        XCTAssertNil(parsed.text)
        XCTAssertNil(parsed.finishReason)
        XCTAssertTrue(parsed.toolCallDeltas.isEmpty)
    }

    // MARK: - Tool-call reassembly (the part that's easy to get wrong)

    func testToolCallIsAssembledAcrossChunks() {
        var partial: [Int: StreamedToolCall] = [:]

        // First chunk: id + name + the opening of the arguments.
        OpenAIClient.merge(chunk("""
        {"index":0,"id":"call_1","type":"function",
         "function":{"name":"get_readiness","arguments":"{\\"da"}}
        """), into: &partial)
        // Later chunks: arguments fragments ONLY — no id, no name.
        OpenAIClient.merge(chunk("""
        {"index":0,"function":{"arguments":"ys\\": 7"}}
        """), into: &partial)
        OpenAIClient.merge(chunk("""
        {"index":0,"function":{"arguments":"}"}}
        """), into: &partial)

        XCTAssertEqual(partial[0]?.id, "call_1")
        XCTAssertEqual(partial[0]?.name, "get_readiness",
                       "only the first chunk names the call — a later empty name must not blank it")
        XCTAssertEqual(OpenAIClient.decodeArguments(partial[0]?.arguments ?? "") as? [String: Int],
                       ["days": 7])
    }

    func testParallelToolCallsAreKeptApartByIndex() {
        var partial: [Int: StreamedToolCall] = [:]
        OpenAIClient.merge(chunk("""
        {"index":0,"id":"a","function":{"name":"get_readiness","arguments":"{}"}}
        """), into: &partial)
        OpenAIClient.merge(chunk("""
        {"index":1,"id":"b","function":{"name":"get_charge_drivers","arguments":"{}"}}
        """), into: &partial)

        XCTAssertEqual(partial.count, 2)
        XCTAssertEqual(partial[0]?.name, "get_readiness")
        XCTAssertEqual(partial[1]?.name, "get_charge_drivers")
    }

    func testMissingIndexDefaultsToTheFirstSlot() {
        var partial: [Int: StreamedToolCall] = [:]
        OpenAIClient.merge(chunk("""
        {"id":"a","function":{"name":"get_readiness","arguments":"{}"}}
        """), into: &partial)
        XCTAssertEqual(partial[0]?.name, "get_readiness", "some gateways omit index for a single call")
    }

    func testMalformedArgumentsDecodeToEmptyRatherThanThrowing() {
        XCTAssertTrue(OpenAIClient.decodeArguments("{\"days\": ").isEmpty,
                      "a truncated argument stream must not abort the reply — the tool then reports "
                      + "what it needs, which the model can recover from")
        XCTAssertTrue(OpenAIClient.decodeArguments("").isEmpty)
    }

    // MARK: - The echoed assistant turn

    func testAssistantTurnCarriesTheCallsBackInWireShape() {
        let turn = OpenAIClient.assistantToolCallTurn(
            text: "",
            calls: [StreamedToolCall(id: "call_1", name: "get_readiness", arguments: "{}")])

        XCTAssertEqual(turn["role"] as? String, "assistant")
        XCTAssertTrue(turn["content"] is NSNull,
                      "the schema expects null, not \"\", when the model emitted no text — some "
                      + "gateways reject an empty string")
        let calls = turn["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(calls?.count, 1)
        XCTAssertEqual((calls?.first?["function"] as? [String: Any])?["name"] as? String,
                       "get_readiness")
    }

    func testAssistantTurnKeepsTextEmittedAlongsideTheCalls() {
        let turn = OpenAIClient.assistantToolCallTurn(
            text: "Ich schaue kurz nach.",
            calls: [StreamedToolCall(id: "c", name: "get_readiness", arguments: "{}")])
        XCTAssertEqual(turn["content"] as? String, "Ich schaue kurz nach.")
    }

    // MARK: - Who streams, and who deliberately doesn't get tools

    func testOpenAIOpenRouterAndCustomAllStream() {
        XCTAssertTrue(AIProvider.openAI.client is StreamingToolClient)
        XCTAssertTrue(AIProvider.openRouter.client is StreamingToolClient)
        XCTAssertTrue(AIProvider.custom.client is StreamingToolClient,
                      "the local-server case is exactly the one that needs streaming most")
    }

    /// Streaming must NOT drag tool-calling into Custom with it. That exclusion is deliberate: tool
    /// support on a local server depends on both server and model, and many local models fail silently
    /// or emit malformed JSON rather than a clean error.
    func testCustomStreamsButStillGetsNoTools() {
        XCTAssertFalse(AIProvider.custom.client is ToolCallingClient)
    }

    func testStreamRoundCapMatchesTheNonStreamingLoop() {
        XCTAssertEqual(OpenAIClient.maxStreamToolRounds, OpenAIClient.maxToolRounds,
                       "a model that loops must be stopped at the same point either way")
    }
}
