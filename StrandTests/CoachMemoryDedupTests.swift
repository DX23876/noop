import XCTest
@testable import Strand

/// The memory-duplication guard rails (#coach-bugs).
///
/// Two mechanisms stop "Summarise past chats" from stacking the same fact twice, and each is pinned here
/// because each alone is insufficient: the WATERMARK stops an already-processed chat being re-sent to the
/// cheap model at all, and the token-overlap arm of the DEDUP collapses the rewordings that get through
/// anyway (a small model asked twice about one conversation rarely phrases a fact identically). Pure
/// model tests — no engine, no provider, no disk.
@MainActor
final class CoachMemoryDedupTests: XCTestCase {

    private func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, text: text) }
    private func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, text: text) }

    /// A memory backed by a throwaway suite, so tests never touch the user's real facts.
    private func freshMemory() -> CoachMemory {
        let suite = "CoachMemoryDedupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return CoachMemory(defaults: defaults)
    }

    // MARK: - Watermark: an already-summarised chat is not reprocessed

    func testNewMessageCountIsZeroWhenEverythingIsSummarised() {
        let convo = CoachConversation(messages: [user("hi"), assistant("hello")],
                                      summary: "A greeting.", summarizedCount: 2)
        XCTAssertEqual(AICoachEngine.newMessageCount(in: convo), 0)
    }

    func testNewMessageCountCountsOnlyTurnsAfterTheWatermark() {
        let convo = CoachConversation(messages: [user("hi"), assistant("hello"), user("and my knee?")],
                                      summary: "A greeting.", summarizedCount: 2)
        XCTAssertEqual(AICoachEngine.newMessageCount(in: convo), 1)
    }

    func testNeverSummarisedConversationCountsEveryMessage() {
        let convo = CoachConversation(messages: [user("hi"), assistant("hello")])
        XCTAssertEqual(AICoachEngine.newMessageCount(in: convo), 2)
    }

    /// The core of the duplicate bug: a second run must send only the NEW turns, so the old ones can't
    /// produce a second copy of the same durable fact.
    func testUnsummarizedTailExcludesAlreadyProcessedTurns() {
        let convo = CoachConversation(messages: [user("my knee hurts"), assistant("noted"), user("and I run 3x")],
                                      summary: "Knee.", summarizedCount: 2)
        let tail = AICoachEngine.unsummarizedTail(of: convo)
        XCTAssertEqual(tail.map(\.text), ["and I run 3x"])
    }

    func testUnsummarizedTailDropsEmptyChartHostTurns() {
        let convo = CoachConversation(messages: [user("show me"), assistant("")])
        XCTAssertEqual(AICoachEngine.unsummarizedTail(of: convo).map(\.text), ["show me"])
    }

    /// A watermark ahead of the message count (a trimmed conversation) must not crash or resurrect turns.
    func testUnsummarizedTailIsEmptyWhenWatermarkExceedsMessageCount() {
        let convo = CoachConversation(messages: [user("hi")], summarizedCount: 9)
        XCTAssertTrue(AICoachEngine.unsummarizedTail(of: convo).isEmpty)
    }

    // MARK: - Dedup: a reworded fact updates in place rather than stacking

    func testRewordedFactCollapsesOntoTheExistingOne() {
        let memory = freshMemory()
        memory.add("Runs three times a week before work")
        memory.add("The user runs three times per week before work")
        XCTAssertEqual(memory.facts.count, 1)
    }

    func testIdenticalFactStillCollapses() {
        let memory = freshMemory()
        memory.add("Left knee pain when running downhill")
        memory.add("left knee pain when running downhill.")
        XCTAssertEqual(memory.facts.count, 1)
    }

    /// The guard rail on the guard rail: unrelated facts must survive, or memory would quietly eat them.
    func testUnrelatedFactsAreKeptSeparate() {
        let memory = freshMemory()
        memory.add("Left knee pain when running downhill")
        memory.add("Trains for a half marathon in October")
        memory.add("Prefers morning sessions before work")
        XCTAssertEqual(memory.facts.count, 3)
    }

    /// Short facts fall back to the string tests: two-word facts share vocabulary far too easily for
    /// overlap to mean anything.
    func testShortSimilarFactsAreNotCollapsedByOverlapAlone() {
        XCTAssertFalse(CoachMemory.hasDuplicateTokenOverlap("knee pain", "knee sore"))
    }

    func testOverlapMatchNeedsNearTotalSharedVocabulary() {
        // Half the words in common is a different fact, not a rewording.
        XCTAssertFalse(CoachMemory.hasDuplicateTokenOverlap("sleeps badly before races",
                                                            "eats badly before races anyway honestly"))
    }

    /// A fact that merely ADDS detail to a known one supersedes it (the store keeps the newer text), so
    /// the 40-slot budget isn't spent on two versions of one thing.
    func testMoreDetailedRestatementSupersedesTheOriginal() {
        let memory = freshMemory()
        memory.add("Trains for a half marathon in October")
        memory.add("Trains for a half marathon in October in Berlin")
        XCTAssertEqual(memory.facts.count, 1)
        XCTAssertEqual(memory.facts.first?.text, "Trains for a half marathon in October in Berlin")
    }
}
