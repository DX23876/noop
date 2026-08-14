import XCTest
@testable import Strand

/// Where the coach's two memory layers meet: the short-term transcript cap and the long-term
/// summariser's watermark.
///
/// `summarizedCount` is an index into `messages`, and `appendMessage` shortens that array from the
/// FRONT. Nothing kept the two in step, so once a conversation reached `maxStoredMessages` its count
/// stuck at the cap — a watermark written there made `newMessageCount` read 0 and `unsummarizedTail`
/// come back empty for the rest of that chat's life. It never produced another summary and never
/// distilled another fact, however long the user kept talking, and the frozen summary is what the
/// semantic index kept serving to cross-conversation recall.
///
/// These drive the real engine because the bug lives in the interaction, not in either piece alone.
@MainActor
final class CoachMemoryWatermarkTests: XCTestCase {

    private func engine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-watermark-\(UUID().uuidString)"))
    }

    /// Fill past the cap, so the front of the transcript is trimmed.
    private func fill(_ engine: AICoachEngine, _ count: Int) {
        for i in 0..<count {
            engine.appendMessage(ChatMessage(role: .user, text: "q\(i)"))
        }
    }

    func testTrimmingTheTranscriptMovesTheWatermarkWithIt() {
        let engine = engine()
        engine.newConversation()
        fill(engine, 40)
        guard let id = engine.activeConversationID else { return XCTFail("no active conversation") }

        // Summarised at the cap: watermark == every message currently held.
        engine.applySummary(conversationID: id, summary: "so far", summarizedCount: engine.messages.count)
        XCTAssertEqual(engine.activeConversation.map(AICoachEngine.newMessageCount), 0,
                       "premise: nothing new immediately after summarising")

        // Six more turns. The count stays pinned at the cap, so only a shifted watermark can show them.
        fill(engine, 6)

        XCTAssertEqual(engine.activeConversation.map(AICoachEngine.newMessageCount), 6,
                       "six new turns must be visible to the summariser")
    }

    /// The other half: the tail actually handed to the cheap model must be the NEW turns, not empty
    /// (which is what made `runSummary` return before spending anything) and not the whole window.
    func testUnsummarizedTailIsTheNewTurnsAfterATrim() {
        let engine = engine()
        engine.newConversation()
        fill(engine, 40)
        guard let id = engine.activeConversationID else { return XCTFail("no active conversation") }
        engine.applySummary(conversationID: id, summary: "so far", summarizedCount: engine.messages.count)

        engine.appendMessage(ChatMessage(role: .user, text: "brand new question"))

        guard let convo = engine.activeConversation else { return XCTFail("no active conversation") }
        let tail = AICoachEngine.unsummarizedTail(of: convo)
        XCTAssertEqual(tail.map(\.text), ["brand new question"],
                       "exactly the turns that have not been distilled yet")
    }

    /// A conversation that has never been summarised has no watermark to move, and trimming must not
    /// invent one — `nil` means "nothing distilled yet", which is not the same as "distilled zero".
    func testTrimmingLeavesAnUnsummarisedConversationAlone() {
        let engine = engine()
        engine.newConversation()
        fill(engine, 45)

        XCTAssertNil(engine.activeConversation?.summarizedCount)
        XCTAssertEqual(engine.activeConversation.map(AICoachEngine.newMessageCount),
                       engine.messages.count,
                       "with no watermark every held message still needs distilling")
    }

    /// The watermark can never go negative, however far behind the trim leaves it.
    func testWatermarkNeverGoesNegative() {
        let engine = engine()
        engine.newConversation()
        fill(engine, 40)
        guard let id = engine.activeConversationID else { return XCTFail("no active conversation") }
        engine.applySummary(conversationID: id, summary: "s", summarizedCount: 2)

        fill(engine, 30)

        let watermark = engine.activeConversation?.summarizedCount ?? -1
        XCTAssertGreaterThanOrEqual(watermark, 0)
        XCTAssertEqual(watermark, 0, "trimmed past its watermark, everything held is undistilled")
    }
}
