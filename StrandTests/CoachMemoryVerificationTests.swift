import XCTest
@testable import Strand

@MainActor
final class CoachMemoryVerificationTests: XCTestCase {
    private func memory() -> CoachMemory {
        let name = "CoachMemoryVerificationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return CoachMemory(defaults: defaults)
    }

    func testHealthFactNeedsConfirmationBeforePinnedUse() {
        let memory = memory()
        XCTAssertTrue(memory.add("Linkes Knie ist verletzt.",
                                 category: .injury,
                                 importance: .pinned))
        let fact = try! XCTUnwrap(memory.facts.first)

        XCTAssertEqual(fact.verification, .pendingConfirmation)
        XCTAssertEqual(fact.sensitivity, .health)
        XCTAssertEqual(fact.source, .user)
        XCTAssertEqual(fact.evidence.count, 1)
        XCTAssertTrue(memory.pinnedBlock.isEmpty)

        memory.confirm(fact.id)
        XCTAssertTrue(memory.pinnedBlock.contains("Linkes Knie ist verletzt."))
    }

    func testPreferenceStartsAsHypothesisAndEditKeepsRevision() {
        let memory = memory()
        XCTAssertTrue(memory.add("Joggen am Wochenende passt selten.",
                                 category: .preference))
        let fact = try! XCTUnwrap(memory.facts.first)
        XCTAssertEqual(fact.verification, .hypothesis)

        XCTAssertTrue(memory.update(fact.id,
                                    text: "Joggen am Samstag passt selten.",
                                    confirmedByUser: true))
        let updated = try! XCTUnwrap(memory.facts.first)
        XCTAssertEqual(updated.verification, .confirmed)
        XCTAssertEqual(updated.revisions.map(\.previousText),
                       ["Joggen am Wochenende passt selten."])
    }

    func testRestatementAddsBoundedEvidenceAndPreservesSource() {
        let memory = memory()
        XCTAssertTrue(memory.add("Prefers cycling before work",
                                 category: .preference,
                                 source: .conversationSummary,
                                 referenceID: "chat-1"))
        XCTAssertTrue(memory.add("Prefers cycling before work",
                                 category: .preference,
                                 source: .coachTool))

        let fact = try! XCTUnwrap(memory.facts.first)
        XCTAssertEqual(fact.source, .conversationSummary)
        XCTAssertEqual(fact.evidenceCount, 2)
        XCTAssertEqual(fact.evidence.map(\.source), [.conversationSummary, .coachTool])
        XCTAssertEqual(fact.evidence.first?.referenceID, "chat-1")
    }

    func testDistilledHealthAndGoalLanguageRequiresConfirmation() {
        XCTAssertEqual(CoachMemory.inferredCategory(for: "Blood test showed low ferritin"),
                       .physiology)
        XCTAssertEqual(CoachMemory.inferredCategory(for: "Training for a marathon in October"),
                       .goal)
        XCTAssertEqual(CoachMemory.inferredCategory(for: "Likes quiet evening walks"),
                       .schedule)
    }
}
