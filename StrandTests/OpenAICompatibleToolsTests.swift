import XCTest
@testable import Strand

/// Pins the pure, network-free parts of the OpenAI-compatible tool loop (`OpenAICompatibleTools.swift`),
/// shared by `OpenAIClient` and `OpenRouterClient` — both conform, so either concrete type reaches the
/// same protocol-extension implementation. Tested via `OpenAIClient` for brevity.
final class OpenAICompatibleToolsTests: XCTestCase {

    // MARK: - toolCalls

    func testToolCallsExtractsTheArray() {
        let message: [String: Any] = [
            "role": "assistant",
            "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "get_readiness", "arguments": "{}"]]]
        ]
        XCTAssertEqual(OpenAIClient.toolCalls(in: message).count, 1)
    }

    func testToolCallsIsEmptyOnAFinalAnswer() {
        let message: [String: Any] = ["role": "assistant", "content": "You're at 72 today."]
        XCTAssertTrue(OpenAIClient.toolCalls(in: message).isEmpty)
    }

    // MARK: - parseToolCall

    func testParseToolCallDecodesIdNameAndArguments() {
        let call: [String: Any] = [
            "id": "call_abc",
            "type": "function",
            "function": ["name": "get_recent_workouts", "arguments": "{\"limit\": 3}"]
        ]
        let parsed = OpenAIClient.parseToolCall(call)
        XCTAssertEqual(parsed?.id, "call_abc")
        XCTAssertEqual(parsed?.name, "get_recent_workouts")
        XCTAssertEqual(parsed?.input["limit"] as? Int, 3)
    }

    func testParseToolCallDefaultsToEmptyArgumentsWhenMissing() {
        let call: [String: Any] = ["id": "call_x", "function": ["name": "get_readiness"]]
        let parsed = OpenAICompatibleTools_TestHost.parseToolCall(call)
        XCTAssertEqual(parsed?.name, "get_readiness")
        XCTAssertEqual(parsed?.input.count, 0)
    }

    func testParseToolCallSkipsAnEntryMissingAnId() {
        let call: [String: Any] = ["function": ["name": "get_readiness", "arguments": "{}"]]
        XCTAssertNil(OpenAIClient.parseToolCall(call))
    }

    func testParseToolCallSkipsMalformedArgumentsJSONRatherThanCrashing() {
        let call: [String: Any] = ["id": "call_y", "function": ["name": "get_readiness", "arguments": "{not json"]]
        let parsed = OpenAIClient.parseToolCall(call)
        // Malformed JSON must still yield a callable tool with empty input, not nil — one bad
        // argument payload shouldn't drop the whole tool call.
        XCTAssertEqual(parsed?.name, "get_readiness")
        XCTAssertEqual(parsed?.input.count, 0)
    }

    // MARK: - closingWire (the B1-style fix: keep gathered tool data, don't discard it)

    func testClosingWireFoldsToolResultsIntoTheClosingInstruction() {
        let wire: [[String: Any]] = [
            ["role": "system", "content": "You are a coach."],
            ["role": "user", "content": "How is my readiness?"],
            ["role": "assistant", "tool_calls": [["id": "t1", "function": ["name": "get_readiness", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "t1", "content": "Readiness: MAINTAIN. ACWR 1.1."]
        ]
        let closing = OpenAIClient.closingWire(from: wire)

        let last = closing.last
        XCTAssertEqual(last?["role"] as? String, "user")
        let content = last?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("Readiness: MAINTAIN"), "tool_call data must ride the forcing call")
        XCTAssertTrue(content.contains("Do not request more tools"))
    }

    func testClosingWireDropsToolRoleTurnsAndContentlessAssistantTurns() {
        let wire: [[String: Any]] = [
            ["role": "system", "content": "sys"],
            ["role": "assistant", "tool_calls": [["id": "a", "function": ["name": "x", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "a", "content": "R1"]
        ]
        let closing = OpenAIClient.closingWire(from: wire)
        // No "tool" role and no contentless "assistant" turn should survive as their own entries —
        // only the system turn plus the synthesized closing user turn.
        XCTAssertEqual(closing.map { $0["role"] as? String }, ["system", "user"])
    }

    func testClosingWireWithNoGatheredDataStillEndsInAPlainInstruction() {
        let wire: [[String: Any]] = [["role": "user", "content": "Just a question"]]
        let closing = OpenAIClient.closingWire(from: wire)
        let last = closing.last?["content"] as? String ?? ""
        XCTAssertFalse(last.contains("Data gathered"), "no gathered data → no fabricated data preamble")
        XCTAssertTrue(last.contains("Do not request more tools"))
    }

    // MARK: - openAIFunctionSpec (CoachTool)

    func testOpenAIFunctionSpecWrapsTheSameSchemaAsAnthropicSpec() {
        let tool = CoachTool.readiness
        let spec = tool.openAIFunctionSpec
        XCTAssertEqual(spec["type"] as? String, "function")
        let fn = spec["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, tool.rawValue)
        XCTAssertEqual(fn?["description"] as? String, tool.description)
        XCTAssertNotNil(fn?["parameters"])
    }
}

/// A second concrete conformer, used once above to confirm `OpenRouterClient` reaches the identical
/// protocol-extension implementation as `OpenAIClient` — not a copy.
private typealias OpenAICompatibleTools_TestHost = OpenRouterClient
