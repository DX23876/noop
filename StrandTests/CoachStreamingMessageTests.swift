import XCTest
import StrandDesign
@testable import Strand

/// The streamed reply's message identity — the fields a token-by-token rebuild used to throw away.
///
/// The bug: `appendDelta` rebuilt the in-flight assistant message with a bare
/// `ChatMessage(id:role:text:)` on every token, so `date` reset to "now" with each token and the
/// `localContextUsed` receipt — the audit trail the transcript renders under a reply — was gone after
/// the first one. Since Anthropic and the OpenAI-shaped clients all stream, that was nearly every
/// reply. These tests pin the field-preserving copies that replaced it.
@MainActor
final class CoachStreamingMessageTests: XCTestCase {

    private func seededMessage() -> ChatMessage {
        ChatMessage(id: UUID(), role: .assistant, text: "hello",
                    date: Date(timeIntervalSince1970: 1_700_000_000),
                    toolsUsed: ["get_readiness"],
                    localContextUsed: [.semanticMemory, .readiness],
                    origin: .brief,
                    memoryWrites: [UUID()])
    }

    func testReplacingTextKeepsEveryOtherField() {
        let original = seededMessage()
        let updated = original.replacingText("hello world")

        XCTAssertEqual(updated.text, "hello world")
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.role, original.role)
        XCTAssertEqual(updated.date, original.date, "a streamed token must not restamp the reply")
        XCTAssertEqual(updated.toolsUsed, original.toolsUsed)
        XCTAssertEqual(updated.localContextUsed, original.localContextUsed,
                       "the local-context receipt is the audit trail; streaming must not erase it")
        XCTAssertEqual(updated.origin, original.origin)
        XCTAssertEqual(updated.memoryWrites, original.memoryWrites)
    }

    func testAttachingEvidenceKeepsTextDateAndReceipt() {
        let original = seededMessage()
        let writes = [UUID(), UUID()]
        let updated = original.attaching(toolsUsed: ["get_range_report"], memoryWrites: writes)

        XCTAssertEqual(updated.toolsUsed, ["get_range_report"])
        XCTAssertEqual(updated.memoryWrites, writes)
        XCTAssertEqual(updated.text, original.text)
        XCTAssertEqual(updated.date, original.date)
        XCTAssertEqual(updated.localContextUsed, original.localContextUsed)
        XCTAssertEqual(updated.origin, original.origin)
    }

    /// Accumulating deltas the way the streaming path does must leave the receipt intact at the end —
    /// this is the actual regression, expressed as the loop that caused it.
    func testAccumulatedDeltasPreserveTheReceipt() {
        var message = ChatMessage(role: .assistant, text: "",
                                  date: Date(timeIntervalSince1970: 1_700_000_000),
                                  localContextUsed: [.keywordMemory])
        for delta in ["Da", "s ", "ist ", "gut."] {
            message = message.replacingText(message.text + delta)
        }
        XCTAssertEqual(message.text, "Das ist gut.")
        XCTAssertEqual(message.localContextUsed, [.keywordMemory])
        XCTAssertEqual(message.date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - The stored-transcript cap sweeps chart artifacts

    /// The 40-message cap trims from the front; the charts those messages hosted used to stay behind in
    /// `chartsByMessage` forever — the same unbounded growth the cap itself was introduced to stop.
    func testTrimmingTheTranscriptDropsTheTrimmedMessagesCharts() {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-charts-\(UUID().uuidString)"))
        engine.newConversation()

        let oldest = ChatMessage(role: .assistant, text: "chart host")
        engine.messages = [oldest]
        engine.chartsByMessage[oldest.id] = CoachChartArtifact(
            title: "Weight",
            points: [TrendPoint(date: Date(), value: 80)],
            valueRange: 70...90,
            kind: .other)

        // Push it out of the window.
        for i in 0..<45 {
            engine.appendMessage(ChatMessage(role: .user, text: "q\(i)"))
        }

        XCTAssertFalse(engine.messages.contains { $0.id == oldest.id },
                       "the cap must have trimmed the oldest message")
        XCTAssertNil(engine.chartsByMessage[oldest.id],
                     "a trimmed message can host nothing — its chart must go with it")
        XCTAssertLessThanOrEqual(engine.messages.count, 40)
    }
}
