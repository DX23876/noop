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

    // MARK: - Chunking

    /// Chinese has no spaces, so the word chunker never cut it and the provider truncated whatever
    /// exceeded 384 tokens — the tail of a long note was simply not in the index.
    func testUnsegmentedTextIsChunkedOnCharacters() {
        let note = String(repeating: "我的睡眠质量最近变差了，晚上很难入睡。", count: 32)
        XCTAssertGreaterThan(note.count, 600, "premise: longer than a single chunk")

        let documents = CoachSemanticMemory.documents(
            facts: [],
            conversations: [],
            journalEntries: [JournalEntry(day: "2026-07-20", question: "睡眠",
                                          answeredYes: true, notes: note)],
            proposals: [],
            allowedScopes: [.personalLogs]
        )
        let chunks = documents.filter { $0.sourceKind == .journalNote }

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= CoachSemanticMemory.characterChunkSize })
        XCTAssertEqual(Set(chunks.map(\.documentID)).count, chunks.count)
        XCTAssertEqual(chunks.map(\.chunkIndex), Array(0..<chunks.count))
        // Consecutive chunks overlap, so a sentence sitting on a boundary stays retrievable whole.
        let overlap = String(chunks[0].text.suffix(CoachSemanticMemory.characterChunkOverlap))
        XCTAssertTrue(chunks[1].text.hasPrefix(overlap))
        // The end of the note is now indexed at all — the point of the change.
        XCTAssertTrue(chunks.last!.text.hasSuffix("晚上很难入睡。"))
    }

    /// The other half of the same change: text WITH word boundaries must chunk exactly as before, or
    /// every stored document changes its `contentHash` and the whole index is re-embedded.
    func testTextWithWordBoundariesKeepsTheWordChunking() {
        let long = (1...500).map { "Wort\($0)" }.joined(separator: " ")
        let documents = CoachSemanticMemory.documents(
            facts: [],
            conversations: [],
            journalEntries: [JournalEntry(day: "2026-07-20", question: "Notiz",
                                          answeredYes: true, notes: long)],
            proposals: [],
            allowedScopes: [.personalLogs]
        )
        let chunks = documents.filter { $0.sourceKind == .journalNote }

        // 192-word window, 24-word overlap, first chunk carrying the day/question preamble.
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].text.split(separator: " ").count, 192)
        XCTAssertTrue(chunks[0].text.hasPrefix("2026-07-20: Notiz"))
        XCTAssertTrue(chunks.last!.text.hasSuffix("Wort500"))
    }
}

/// The rebuild gate: how complete the index has to be before searching it beats not searching it.
///
/// A model change marks every row of the old model `pending`, and `search` skips those, so the index is
/// genuinely part-empty for a while. Measured on a 404-query corpus, nDCG@8 runs 0.302 / 0.387 / 0.444 / 0.508 /
/// 0.576 / 0.713 at 25 / 40 / 50 / 60 / 75 / 100 % embedded, against 0.479 for the keyword arm alone — so below
/// roughly 55 % the semantic arm is worse than not using it, while still emitting eight confident lines.
@MainActor
final class CoachSemanticRebuildGateTests: XCTestCase {

    func testAMostlyEmbeddedIndexIsSearchedSemantically() {
        XCTAssertTrue(CoachSemanticMemory.shouldSearchSemantically(indexed: 1_000, pending: 0))
        XCTAssertTrue(CoachSemanticMemory.shouldSearchSemantically(indexed: 950, pending: 50))
        // Exactly at the threshold counts as enough: the comparison is >=, so 60 % is inside.
        XCTAssertTrue(CoachSemanticMemory.shouldSearchSemantically(indexed: 60, pending: 40))
    }

    func testAHalfRebuiltIndexFallsBackToTheKeywordArm() {
        XCTAssertFalse(CoachSemanticMemory.shouldSearchSemantically(indexed: 50, pending: 50))
        XCTAssertFalse(CoachSemanticMemory.shouldSearchSemantically(indexed: 25, pending: 75))
        XCTAssertFalse(CoachSemanticMemory.shouldSearchSemantically(indexed: 59, pending: 41))
    }

    /// First launch and a freshly invalidated index are the same case, and neither needs its own branch.
    func testAnEmptyOrFreshlyInvalidatedIndexIsNotSearched() {
        XCTAssertFalse(CoachSemanticMemory.shouldSearchSemantically(indexed: 0, pending: 0))
        XCTAssertFalse(CoachSemanticMemory.shouldSearchSemantically(indexed: 0, pending: 4_000))
    }

    /// Ordinary incremental indexing must NOT trip the gate: a handful of newly enqueued chunks against a
    /// populated index is a negligible share, and gating there would disable retrieval after every conversation.
    func testNewlyEnqueuedChunksOnAPopulatedIndexDoNotTripTheGate() {
        XCTAssertTrue(CoachSemanticMemory.shouldSearchSemantically(indexed: 4_000, pending: 64))
        XCTAssertTrue(CoachSemanticMemory.shouldSearchSemantically(indexed: 500, pending: 32))
    }

    /// The threshold sits ABOVE the measured crossing point on purpose: six points do not justify two decimal
    /// places, and the error belongs on the side of never sitting where semantic retrieval loses.
    func testTheThresholdIsAboveTheMeasuredCrossingPoint() {
        XCTAssertGreaterThan(CoachSemanticMemory.minimumEmbeddedShareForSemanticSearch, 0.55)
        XCTAssertLessThan(CoachSemanticMemory.minimumEmbeddedShareForSemanticSearch, 0.75)
    }
}
