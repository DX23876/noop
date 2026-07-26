import XCTest
@testable import Strand

final class CoachMemoryFootprintTests: XCTestCase {
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
