import XCTest
@testable import Strand

/// Two wire-level invariants, each pinning a fixed bug.
///
/// 1. `AICoachEngine.wirePairs` must never emit an empty turn: `flushPendingCharts` appends one empty
///    assistant message per chart as a chart host, and Anthropic rejects empty content — so a
///    follow-up question after a chart used to risk a 400.
/// 2. `AnthropicClient.messagesForFinal` must CARRY the tool_result data into the forcing call:
///    it used to drop every block turn and then tell the model to "answer using the data gathered
///    above" — data that was no longer in the request.
final class CoachWireHygieneTests: XCTestCase {

    // MARK: - wirePairs: empty chart-host turns stay off the wire

    func testEmptyAssistantChartHostIsFiltered() {
        let windowed = [
            ChatMessage(role: .user, text: "Plot my HRV"),
            ChatMessage(role: .assistant, text: "Here is your HRV trend."),
            ChatMessage(role: .assistant, text: ""),   // chart host from flushPendingCharts
            ChatMessage(role: .user, text: "What does the dip mean?")
        ]
        let wire = AICoachEngine.wirePairs(from: windowed, context: "CTX")

        XCTAssertEqual(wire.count, 3)
        XCTAssertFalse(wire.contains { $0.content.isEmpty })
        // T4: the context rides the LAST user turn (the actual question), not the first.
        XCTAssertEqual(wire[0].content, "Plot my HRV")
        XCTAssertTrue(wire[2].content.hasPrefix("CTX"))
        XCTAssertTrue(wire[2].content.hasSuffix("What does the dip mean?"))
    }

    /// T4 empty-context edge: with a blank context (the tool path with no pending proposals — the stable
    /// prose now lives in the cached system block), the question rides the wire ALONE, never wrapped in a
    /// "\n\n---\n\nQuestion:" scaffold around nothing.
    func testBlankContextSendsTheQuestionAloneWithNoScaffold() {
        let windowed = [
            ChatMessage(role: .user, text: "How's my recovery?")
        ]
        let wire = AICoachEngine.wirePairs(from: windowed, context: "   \n  ")
        XCTAssertEqual(wire.count, 1)
        XCTAssertEqual(wire[0].content, "How's my recovery?")
        XCTAssertFalse(wire[0].content.contains("---"))
        XCTAssertFalse(wire[0].content.contains("Question:"))
    }

    /// A transcript with no user turn at all must not crash and must inject the context nowhere (the
    /// context is dropped rather than fabricated onto an assistant turn).
    func testNoUserTurnDoesNotCrashAndInjectsNowhere() {
        let windowed = [ChatMessage(role: .assistant, text: "Today's brief\n\n…")]
        let wire = AICoachEngine.wirePairs(from: windowed, context: "CTX")
        XCTAssertEqual(wire.count, 1)
        XCTAssertEqual(wire[0].content, "Today's brief\n\n…")
    }

    func testChartOnlyReplyStillYieldsValidWire() {
        // A turn whose reply was ONLY a chart: the empty text bubble was removed, the host remains.
        let windowed = [
            ChatMessage(role: .user, text: "Chart my sleep"),
            ChatMessage(role: .assistant, text: ""),   // chart host
            ChatMessage(role: .user, text: "And now compare to last month")
        ]
        let wire = AICoachEngine.wirePairs(from: windowed, context: "CTX")

        XCTAssertEqual(wire.map { $0.role }, [.user, .user])
        XCTAssertFalse(wire.contains { $0.content.isEmpty })
    }

    func testNoChartsPassesThroughUnchanged() {
        let windowed = [
            ChatMessage(role: .user, text: "Hello"),
            ChatMessage(role: .assistant, text: "Hi!")
        ]
        let wire = AICoachEngine.wirePairs(from: windowed, context: "CTX")
        XCTAssertEqual(wire.count, 2)
        XCTAssertEqual(wire[1].content, "Hi!")
    }

    // MARK: - messagesForFinal: the forcing call keeps the gathered tool data

    func testToolResultsSurviveIntoForcingCall() {
        let wire: [[String: Any]] = [
            ["role": "user", "content": "How is my readiness?"],
            ["role": "assistant", "content": [
                ["type": "text", "text": "Let me check."],
                ["type": "tool_use", "id": "t1", "name": "get_readiness", "input": [:]]
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "Readiness: MAINTAIN. ACWR 1.1, monotony low."]
            ]]
        ]
        let final = AnthropicClient.messagesForFinal(wire: wire)

        let closing = final.last
        XCTAssertEqual(closing?.role, .user)
        // The data the instruction refers to must actually be in the request.
        XCTAssertTrue(closing?.content.contains("Readiness: MAINTAIN") == true,
                      "tool_result content must ride the forcing call")
        XCTAssertTrue(closing?.content.contains("Do not request more tools") == true)
        // Assistant interstitial text is preserved too.
        XCTAssertTrue(final.contains { $0.role == .assistant && $0.content.contains("Let me check.") })
    }

    func testRolesAlternateAfterDroppingToolTurns() {
        // Two tool rounds back to back: dropping the tool_use/tool_result plumbing used to leave
        // consecutive same-role turns, which the API rejects.
        let wire: [[String: Any]] = [
            ["role": "user", "content": "Question"],
            ["role": "assistant", "content": [["type": "tool_use", "id": "a", "name": "x", "input": [:]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "a", "content": "R1"]]],
            ["role": "assistant", "content": [["type": "tool_use", "id": "b", "name": "y", "input": [:]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "b", "content": "R2"]]]
        ]
        let final = AnthropicClient.messagesForFinal(wire: wire)

        for i in 1..<final.count {
            XCTAssertNotEqual(final[i].role, final[i - 1].role, "turns must alternate at index \(i)")
        }
        // Both rounds' data made it in.
        let joined = final.map { $0.content }.joined()
        XCTAssertTrue(joined.contains("R1"))
        XCTAssertTrue(joined.contains("R2"))
    }

    func testNoToolDataKeepsPlainClosing() {
        let wire: [[String: Any]] = [["role": "user", "content": "Just a question"]]
        let final = AnthropicClient.messagesForFinal(wire: wire)
        // Question and closing instruction are both user turns → coalesced into one.
        XCTAssertEqual(final.count, 1)
        XCTAssertTrue(final[0].content.contains("Just a question"))
        XCTAssertTrue(final[0].content.contains("Do not request more tools"))
        XCTAssertFalse(final[0].content.contains("Data gathered"),
                       "no gathered data → no fabricated data preamble")
    }
}
