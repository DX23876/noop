import XCTest
import SemanticMemory
import WhoopStore
@testable import Strand

@MainActor
final class CoachSemanticMemorySourceTests: XCTestCase {
    func testOnlyUserConversationTextAndAllowedJournalTextAreIndexed() {
        let user = ChatMessage(id: UUID(), role: .user, text: "Mein Knie mag lockeres Radfahren.")
        let assistant = ChatMessage(id: UUID(), role: .assistant, text: "Du solltest heute laufen.")
        let conversation = CoachConversation(
            title: "Knie und Training",
            messages: [user, assistant],
            summary: "Der Nutzer bevorzugt bei Knieschmerz lockeres Radfahren."
        )
        let journal = JournalEntry(day: "2026-07-20",
                                   question: "Eigene Abendroutine",
                                   answeredYes: false,
                                   notes: "Sehr spät",
                                   numericValue: 250)
        let sensitive = JournalEntry(day: "2026-07-21",
                                     question: "CBD-Öl verwendet",
                                     answeredYes: true,
                                     notes: nil)

        let documents = CoachSemanticMemory.documents(
            facts: [],
            conversations: [conversation],
            journalEntries: [journal, sensitive],
            proposals: [],
            allowedScopes: [.memory, .personalLogs]
        )
        let text = documents.map(\.text).joined(separator: "\n")

        XCTAssertTrue(text.contains(user.text))
        XCTAssertFalse(text.contains(assistant.text))
        XCTAssertTrue(text.contains("Eigene Abendroutine — Nein"))
        XCTAssertTrue(text.contains("Sehr spät"))
        XCTAssertFalse(text.contains("250"))
        XCTAssertFalse(text.contains("CBD-Öl verwendet"))
    }

    func testSensitiveJournalNeedsItsOwnScopeAndFactsKeepPriority() {
        let fact = CoachMemory.MemoryFact(text: "Linkes Knie ist verletzt.",
                                          category: .injury,
                                          importance: .pinned)
        let sensitive = JournalEntry(day: "2026-07-21",
                                     question: "CBD-Öl verwendet",
                                     answeredYes: true,
                                     notes: "Vor dem Schlafen")
        let documents = CoachSemanticMemory.documents(
            facts: [fact],
            conversations: [],
            journalEntries: [sensitive],
            proposals: [],
            allowedScopes: [.memory, .sensitiveLogs]
        )

        XCTAssertEqual(documents.first(where: { $0.sourceKind == .memoryFact })?.priority, 120)
        XCTAssertTrue(documents.contains {
            $0.sourceKind == .journalQuestion && $0.consentScope == .sensitiveLogs
        })
    }

    func testRecommendationOutcomesAndHabitWindowsNeedPatternsScope() {
        let proposals = [
            PlanProposal(day: "2026-07-04", sport: "Jogging", intent: .easy,
                         status: .declined, decidedAt: Date()),
            PlanProposal(day: "2026-07-05", sport: "Jogging", intent: .easy,
                         status: .skipped, skipReason: .noTime, decidedAt: Date()),
            PlanProposal(day: "2026-07-11", sport: "Jogging", intent: .easy,
                         status: .completed, decidedAt: Date(),
                         effectFeedback: .negativeEffect,
                         feedbackNote: "Knee felt worse")
        ]

        let denied = CoachSemanticMemory.documents(
            facts: [], conversations: [], journalEntries: [], proposals: proposals,
            allowedScopes: [.memory]
        )
        XCTAssertFalse(denied.contains { $0.sourceKind == .recommendationFeedback })

        let allowed = CoachSemanticMemory.documents(
            facts: [], conversations: [], journalEntries: [], proposals: proposals,
            allowedScopes: [.patterns]
        )
        let text = allowed.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Recommendation declined"))
        XCTAssertTrue(text.contains("not completed: No time"))
        XCTAssertTrue(text.contains("Felt worse"))
        XCTAssertTrue(text.contains("Knee felt worse"))
        XCTAssertTrue(allowed.contains { $0.sourceKind == .habitHypothesis })
        XCTAssertTrue(allowed.allSatisfy { $0.consentScope == .patterns })
    }
}
