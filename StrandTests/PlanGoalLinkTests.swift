import XCTest
@testable import Strand

/// Linking a planned session to the goal it serves (#coach-bugs).
///
/// The property defended here: linking can only ever make the Journey page's count MORE accurate, never
/// less complete. Every session that counted before still counts — the link only stops one goal's work
/// from being counted as another goal's progress now that several can be active at once.
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

    // MARK: - Counting for a goal

    func testUnlinkedSessionsSinceTheGoalStartedStillCount() {
        let store = makeStore()
        let goalId = UUID()
        completed(store, day: "2026-07-16", sport: "Zone 2 ride", goalId: nil)
        XCTAssertEqual(store.completedSessions(forGoal: goalId, since: "2026-07-01").count, 1,
                       "sessions predating the link must keep counting, or upgrading would erase progress")
    }

    func testUnlinkedSessionsBeforeTheGoalStartedDoNotCount() {
        let store = makeStore()
        completed(store, day: "2026-06-01", sport: "Old ride", goalId: nil)
        XCTAssertTrue(store.completedSessions(forGoal: UUID(), since: "2026-07-01").isEmpty)
    }

    func testSessionLinkedToThisGoalCountsEvenBeforeItsCutoff() {
        let store = makeStore()
        let goalId = UUID()
        completed(store, day: "2026-06-01", sport: "Linked ride", goalId: goalId)
        XCTAssertEqual(store.completedSessions(forGoal: goalId, since: "2026-07-01").count, 1)
    }

    /// The actual improvement: another goal's work is no longer counted as this goal's.
    func testSessionLinkedToAnotherGoalIsExcluded() {
        let store = makeStore()
        let mine = UUID(), theirs = UUID()
        completed(store, day: "2026-07-16", sport: "Their strength session", goalId: theirs)
        XCTAssertTrue(store.completedSessions(forGoal: mine, since: "2026-07-01").isEmpty)
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
}
