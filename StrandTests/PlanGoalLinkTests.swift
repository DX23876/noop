import XCTest
@testable import Strand

/// Linking a planned session to every goal it genuinely serves (#coach-bugs).
///
/// The property defended here: a session is stored once, may support several explicitly selected
/// Journeys, and never leaks into an unselected goal. General sessions remain unlinked.
@MainActor
final class PlanGoalLinkTests: XCTestCase {

    private func makeStore() -> CoachPlanStore { CoachPlanStore(loading: false) }

    private func completed(_ store: CoachPlanStore, day: String, sport: String, goalId: UUID?) {
        store.addUserSession(day: day, time: nil, sport: sport, intent: .easy, goalId: goalId)
        if let id = store.proposals.first(where: { $0.sport == sport && $0.day == day })?.id {
            store.complete(id)
        }
    }

    // MARK: - Back-compat: stored plans predate the field entirely

    func testDecodesStoredProposalWithoutGoalIdAsUnlinked() throws {
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "day": "2026-07-16",
          "sport": "Zone 2 ride",
          "intent": "easy",
          "rationale": "",
          "status": "completed",
          "source": "coachProposed",
          "createdAt": 700000000
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PlanProposal.self, from: legacy)
        XCTAssertNil(decoded.goalId)
        XCTAssertEqual(decoded.sport, "Zone 2 ride")
    }

    func testGoalIdSurvivesARoundTrip() throws {
        let goalId = UUID()
        let p = PlanProposal(day: "2026-07-16", sport: "Tempo run", intent: .hard, goalId: goalId)
        let decoded = try JSONDecoder().decode(PlanProposal.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.goalId, goalId)
    }

    func testLegacyGoalIdMigratesIntoGoalIds() throws {
        let goalId = UUID()
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "day": "2026-07-16",
          "sport": "Walk",
          "intent": "easy",
          "rationale": "",
          "status": "completed",
          "source": "userCreated",
          "goalId": "\(goalId.uuidString)",
          "createdAt": 700000000
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PlanProposal.self, from: legacy)

        XCTAssertEqual(decoded.goalIds, [goalId])
        XCTAssertEqual(decoded.goalId, goalId)
    }

    func testSeveralGoalIdsRoundTripWithoutDuplicates() throws {
        let first = UUID(), second = UUID()
        let proposal = PlanProposal(day: "2026-07-16", sport: "Walk", intent: .easy,
                                    goalIds: [first, second, first])

        let decoded = try JSONDecoder().decode(PlanProposal.self,
                                               from: JSONEncoder().encode(proposal))

        XCTAssertEqual(decoded.goalIds, [first, second])
        XCTAssertTrue(decoded.serves(first))
        XCTAssertTrue(decoded.serves(second))
    }

    // MARK: - Counting for a goal

    func testUnlinkedSessionsDoNotCountForASpecificGoal() {
        let store = makeStore()
        let goalId = UUID()
        completed(store, day: "2026-07-16", sport: "Zone 2 ride", goalId: nil)
        XCTAssertTrue(store.completedSessions(forGoal: goalId, since: "2026-07-01").isEmpty)
    }

    func testUnlinkedSessionsBeforeTheGoalStartedDoNotCount() {
        let store = makeStore()
        completed(store, day: "2026-06-01", sport: "Old ride", goalId: nil)
        XCTAssertTrue(store.completedSessions(forGoal: UUID(), since: "2026-07-01").isEmpty)
    }

    func testSessionLinkedToThisGoalBeforeItsCutoffDoesNotCount() {
        let store = makeStore()
        let goalId = UUID()
        completed(store, day: "2026-06-01", sport: "Linked ride", goalId: goalId)
        XCTAssertTrue(store.completedSessions(forGoal: goalId, since: "2026-07-01").isEmpty)
    }

    func testSessionLinkedToThisGoalAfterItsCutoffCounts() {
        let store = makeStore()
        let goalId = UUID()
        completed(store, day: "2026-07-16", sport: "Linked ride", goalId: goalId)
        XCTAssertEqual(store.completedSessions(forGoal: goalId, since: "2026-07-01").count, 1)
    }

    /// The actual improvement: another goal's work is no longer counted as this goal's.
    func testSessionLinkedToAnotherGoalIsExcluded() {
        let store = makeStore()
        let mine = UUID(), theirs = UUID()
        completed(store, day: "2026-07-16", sport: "Their strength session", goalId: theirs)
        XCTAssertTrue(store.completedSessions(forGoal: mine, since: "2026-07-01").isEmpty)
    }

    func testOneSessionCanCountForTwoExplicitlyLinkedGoals() {
        let store = makeStore()
        let movement = UUID(), wellbeing = UUID(), unrelated = UUID()
        store.addUserSession(day: "2026-07-16", time: nil, sport: "Walk", intent: .easy,
                             goalIds: [movement, wellbeing])
        store.complete(store.proposals[0].id)

        XCTAssertEqual(store.completedSessions(forGoal: movement, since: "2026-07-01").count, 1)
        XCTAssertEqual(store.completedSessions(forGoal: wellbeing, since: "2026-07-01").count, 1)
        XCTAssertTrue(store.completedSessions(forGoal: unrelated, since: "2026-07-01").isEmpty)
    }

    func testOnlyCompletedSessionsCount() {
        let store = makeStore()
        let goalId = UUID()
        // Accepted but never completed.
        store.addUserSession(day: "2026-07-16", time: nil, sport: "Planned ride", intent: .easy,
                             goalId: goalId)
        XCTAssertTrue(store.completedSessions(forGoal: goalId, since: "2026-07-01").isEmpty)
    }

    // MARK: - Re-proposal keeps the link

    func testReProposalDoesNotDropAnExistingLink() {
        let store = makeStore()
        let goalId = UUID()
        store.propose(PlanProposal(day: "2026-07-16", sport: "Zone 2 ride", intent: .easy, goalId: goalId))
        store.propose(PlanProposal(day: "2026-07-16", sport: "Zone 2 ride", intent: .moderate))
        XCTAssertEqual(store.proposals.count, 1)
        XCTAssertEqual(store.proposals.first?.goalId, goalId)
        XCTAssertEqual(store.proposals.first?.intent, .moderate, "the re-proposal still supersedes")
    }

    func testReProposalDoesNotDropExistingMultiGoalLinks() {
        let store = makeStore()
        let first = UUID(), second = UUID()
        store.propose(PlanProposal(day: "2026-07-16", sport: "Walk", intent: .easy,
                                   goalIds: [first, second]))
        store.propose(PlanProposal(day: "2026-07-16", sport: "Walk", intent: .moderate))

        XCTAssertEqual(store.proposals.first?.goalIds, [first, second])
    }
}
