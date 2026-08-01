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
        // The answer label follows the app's language. It used to be a hardcoded "Ja"/"Nein" for all
        // nine shipped languages — text that is both embedded by Nomic and handed to the model as
        // context, so it embedded a token the user's own questions could never match. Asserted through
        // the catalog rather than as a literal, so this pins the composition without re-pinning one
        // language's spelling.
        XCTAssertTrue(text.contains("Eigene Abendroutine — \(String(localized: "No"))"))
        XCTAssertTrue(text.contains("Sehr spät"))
        XCTAssertFalse(text.contains("250"))
        XCTAssertFalse(text.contains("CBD-Öl verwendet"))
    }

    // MARK: - Incremental reconcile

    /// The reconcile runs on the send path, before every request. It used to UPSERT every document of
    /// the whole retained history each time; these pin that it now writes only what changed.
    func testAReconcileOverUnchangedSourcesHasNothingToWrite() {
        let documents = CoachSemanticMemory.documents(
            facts: [CoachMemory.MemoryFact(text: "Linkes Knie ist verletzt.", category: .injury)],
            conversations: [],
            journalEntries: [],
            proposals: [],
            allowedScopes: [.memory]
        )
        XCTAssertFalse(documents.isEmpty, "premise: there is something to reconcile")

        let first = CoachSemanticMemory.delta(of: documents, since: [:])
        XCTAssertEqual(first.changed.count, documents.count, "a cold start writes everything")
        XCTAssertTrue(first.idsChanged)

        let second = CoachSemanticMemory.delta(of: documents, since: first.hashes)
        XCTAssertTrue(second.changed.isEmpty, "nothing changed, so nothing may be enqueued")
        XCTAssertFalse(second.idsChanged, "and no full-table scan for deletions either")
        XCTAssertEqual(second.hashes, first.hashes)
    }

    /// Ids are held fixed so this measures an EDIT, not two unrelated facts: a document is keyed by its
    /// fact id, and a fresh id is simply a new document.
    func testOnlyTheEditedDocumentIsWritten() {
        let runs = UUID(), swims = UUID()
        let documents = { (runsText: String) in
            CoachSemanticMemory.documents(
                facts: [CoachMemory.MemoryFact(id: runs, text: runsText, category: .schedule),
                        CoachMemory.MemoryFact(id: swims, text: "Swims on Fridays.", category: .schedule)],
                conversations: [], journalEntries: [], proposals: [], allowedScopes: [.memory])
        }

        let baseline = CoachSemanticMemory.delta(of: documents("Runs on Tuesdays."), since: [:]).hashes
        let delta = CoachSemanticMemory.delta(of: documents("Runs on Wednesdays."), since: baseline)
        XCTAssertEqual(delta.changed.count, 1, "only the edited fact may be re-enqueued")
        XCTAssertTrue(try! XCTUnwrap(delta.changed.first).text.contains("Wednesdays"))
        XCTAssertFalse(delta.idsChanged, "an edit in place orphans nothing, so no deletion scan")
    }

    /// A document that disappears has to force the deletion scan even though nothing was rewritten.
    func testARemovedDocumentStillTriggersTheDeletionScan() {
        let before = CoachSemanticMemory.documents(
            facts: [CoachMemory.MemoryFact(text: "Runs on Tuesdays.", category: .schedule),
                    CoachMemory.MemoryFact(text: "Swims on Fridays.", category: .schedule)],
            conversations: [], journalEntries: [], proposals: [], allowedScopes: [.memory])
        let baseline = CoachSemanticMemory.delta(of: before, since: [:]).hashes

        let delta = CoachSemanticMemory.delta(of: Array(before.prefix(1)), since: baseline)
        XCTAssertTrue(delta.changed.isEmpty, "the surviving document is unchanged")
        XCTAssertTrue(delta.idsChanged)
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
