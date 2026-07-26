import XCTest
@testable import Strand

/// The `archived` field and the auto-only classification that drive the day-boundary brief sweep (#R8).
/// Pure model tests — no engine, no Keychain, no disk.
final class CoachConversationArchiveTests: XCTestCase {

    private func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, text: text) }
    private func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, text: text) }

    // MARK: isAutoOnly — only threads the user never replied in can be swept

    func testBriefOnlyThreadIsAutoOnly() {
        let c = CoachConversation(messages: [assistant("Today's brief\n\nRest up.")])
        XCTAssertTrue(c.isAutoOnly)
    }

    func testThreadWithAUserTurnIsNotAutoOnly() {
        let c = CoachConversation(messages: [assistant("Today's brief"), user("thanks")])
        XCTAssertFalse(c.isAutoOnly)
    }

    func testEmptyThreadIsNotAutoOnly() {
        XCTAssertFalse(CoachConversation().isAutoOnly)
    }

    // MARK: Codable back-compat — old JSON has no `archived` key

    func testDecodesLegacyJSONWithoutArchivedKeyAsUnarchived() throws {
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "title": "Old chat",
          "createdAt": 700000000,
          "updatedAt": 700000000,
          "messages": [],
          "charts": {}
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CoachConversation.self, from: legacy)
        XCTAssertFalse(decoded.archived, "A thread saved before #R8 must load as un-archived")
    }

    func testArchivedFlagSurvivesRoundTrip() throws {
        var c = CoachConversation(title: "Brief", messages: [assistant("Today's brief")])
        c.archived = true
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(CoachConversation.self, from: data)
        XCTAssertTrue(back.archived)
        XCTAssertEqual(back.title, "Brief")
    }
}
