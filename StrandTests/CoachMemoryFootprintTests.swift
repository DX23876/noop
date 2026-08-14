import XCTest
import StrandDesign
@testable import Strand

final class CoachMemoryFootprintTests: XCTestCase {

    /// `charts` is keyed by host-message id, so trimming messages without sweeping them strands
    /// snapshots in the JSON — never rendered, but re-parsed on every launch. The live paths already
    /// keep the two in step; this pins the persistence path so raising the live cap can't quietly
    /// start orphaning them.
    func testTrimmingAConversationDropsChartsWithNoMessageLeft() {
        let kept = ChatMessage(role: .assistant, text: "still here")
        let gone = ChatMessage(role: .assistant, text: "")
        let snapshot = CoachChartSnapshot(CoachChartArtifact(
            title: "Weight",
            points: [TrendPoint(date: Date(), value: 80)],
            valueRange: 70...90,
            kind: .other))
        let convo = CoachConversation(
            messages: [kept],
            charts: [kept.id.uuidString: snapshot, gone.id.uuidString: snapshot])

        let trimmed = CoachConversationStore.trimmed(convo)

        XCTAssertNotNil(trimmed.charts[kept.id.uuidString], "a live message keeps its chart")
        XCTAssertNil(trimmed.charts[gone.id.uuidString],
                     "a chart with no message to hang on must not be persisted")
    }

    func testEmptyMemoryHasNoEstimatedBytes() {
        XCTAssertEqual(CoachMemoryFootprint.estimate(conversations: [], facts: []),
                       .init(conversationBytes: 2, factBytes: 2),
                       "empty arrays still have their two JSON bracket bytes")
    }

    func testEstimateCountsConversationAndFactPayloadsIndependently() {
        let conversation = CoachConversation(title: "Sleep", messages: [
            .init(role: .user, text: "How was my sleep?"),
            .init(role: .assistant, text: "Your recent sleep was steady.")
        ])
        let fact = CoachMemory.MemoryFact(text: "Prefers to run in the morning", category: .preference)
        let both = CoachMemoryFootprint.estimate(conversations: [conversation], facts: [fact])
        let chatsOnly = CoachMemoryFootprint.estimate(conversations: [conversation], facts: [])
        let factsOnly = CoachMemoryFootprint.estimate(conversations: [], facts: [fact])

        XCTAssertGreaterThan(both.conversationBytes, 2)
        XCTAssertGreaterThan(both.factBytes, 2)
        XCTAssertEqual(both.totalBytes, chatsOnly.conversationBytes + factsOnly.factBytes)
    }

    func testFormattingUsesAHumanReadableLocalByteCount() {
        XCTAssertFalse(CoachMemoryFootprint.formatted(1_234).isEmpty)
    }
}
