import XCTest
@testable import Strand

/// `CoachNotifier` bridges the coach's structured outputs (`ProactiveSignal`, `PlanProposal`) into the
/// bell (`UpdateStore.shared`). These tests pin: the `ProactiveLevel` gate (a bell post must never bypass
/// a user who turned proactive coaching down/off, exactly like the chat nudge it mirrors), the
/// category/priority mapping, the same-day repost guard, and that a re-proposed `PlanProposal` refreshes
/// its existing bell row instead of duplicating it.
@MainActor
final class CoachNotifierTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UpdateStore.shared.clearAll()
    }

    override func tearDown() {
        UpdateStore.shared.clearAll()
        super.tearDown()
    }

    private func signal(_ category: ProactiveSignal.Category, important: Bool = true,
                        goalId: UUID? = nil) -> ProactiveSignal {
        ProactiveSignal(category: category, important: important, seed: "seed line", goalId: goalId)
    }

    // MARK: - ProactiveLevel gate

    func testOffLevelPostsNothing() {
        CoachNotifier.postProactiveSignal(signal(.bodyConcern), level: .off)
        XCTAssertTrue(UpdateStore.shared.items.isEmpty)
    }

    func testImportantLevelSkipsNonImportantSignals() {
        CoachNotifier.postProactiveSignal(signal(.milestone, important: false), level: .important)
        XCTAssertTrue(UpdateStore.shared.items.isEmpty, "a small win shouldn't reach the bell at "
                     + "\"only important\", same as it wouldn't reach chat")
    }

    func testImportantLevelPostsImportantSignals() {
        CoachNotifier.postProactiveSignal(signal(.setback, important: true), level: .important)
        XCTAssertEqual(UpdateStore.shared.items.count, 1)
    }

    func testNormalLevelPostsNonImportantSignalsToo() {
        CoachNotifier.postProactiveSignal(signal(.milestone, important: false), level: .normal)
        XCTAssertEqual(UpdateStore.shared.items.count, 1)
    }

    // MARK: - Category/priority mapping

    func testBodyConcernMapsToHighPriorityInformative() {
        CoachNotifier.postProactiveSignal(signal(.bodyConcern), level: .normal)
        let item = try? XCTUnwrap(UpdateStore.shared.items.first)
        XCTAssertEqual(item?.category, .informative)
        XCTAssertEqual(item?.priority, .high)
        XCTAssertFalse(item?.actionRequired ?? true, "a hint never asks for a decision")
    }

    func testGoalDeadlineMapsToStatusReminder() {
        CoachNotifier.postProactiveSignal(signal(.goalDeadline, important: false), level: .normal)
        XCTAssertEqual(UpdateStore.shared.items.first?.category, .statusReminder)
    }

    func testNoProactiveSignalEverProducesAnActionableItem() {
        for category: ProactiveSignal.Category in [.milestone, .setback, .bodyConcern,
                                                    .bodyPositive, .goalDeadline] {
            UpdateStore.shared.clearAll()
            CoachNotifier.postProactiveSignal(signal(category, important: true), level: .normal)
            XCTAssertNotEqual(UpdateStore.shared.items.first?.category, .actionable,
                              "\(category) must never produce an actionable (decision-needed) item — "
                              + "only a PlanProposal does")
        }
    }

    // MARK: - Same-day repost guard

    func testSameSignalTwiceSameDayPostsOnce() {
        let s = signal(.bodyConcern)
        CoachNotifier.postProactiveSignal(s, level: .normal)
        CoachNotifier.postProactiveSignal(s, level: .normal)
        XCTAssertEqual(UpdateStore.shared.items.count, 1, "a retried nudge attempt (e.g. after a failed "
                       + "network call) must not duplicate the bell row")
    }

    func testDifferentCategoriesSameDayBothPost() {
        CoachNotifier.postProactiveSignal(signal(.bodyConcern), level: .normal)
        CoachNotifier.postProactiveSignal(signal(.milestone), level: .normal)
        XCTAssertEqual(UpdateStore.shared.items.count, 2)
    }

    // MARK: - postPlanProposal

    private func proposal(id: UUID = UUID(), sport: String = "Zone 2 ride") -> PlanProposal {
        PlanProposal(id: id, day: "2026-07-24", sport: sport, intent: .easy)
    }

    func testPostPlanProposalCreatesActionableItem() {
        let p = proposal()
        CoachNotifier.postPlanProposal(p)
        let item = try? XCTUnwrap(UpdateStore.shared.items.first)
        XCTAssertEqual(item?.category, .actionable)
        XCTAssertTrue(item?.actionRequired ?? false)
        XCTAssertEqual(item?.planProposalId, p.id)
        XCTAssertTrue(item?.showOnToday ?? false)
    }

    /// `CoachPlanStore.propose(_:)` collapses a same-(day, sport) re-proposal onto the SAME id — so a
    /// second `postPlanProposal` call for that id must refresh the existing row, not add a second one.
    func testReproposingTheSameIdRefreshesInPlace() {
        let id = UUID()
        CoachNotifier.postPlanProposal(proposal(id: id, sport: "Zone 2 ride"))
        CoachNotifier.postPlanProposal(proposal(id: id, sport: "Zone 2 ride (updated)"))
        let matching = UpdateStore.shared.items.filter { $0.planProposalId == id }
        XCTAssertEqual(matching.count, 1)
        XCTAssertTrue(matching.first?.message.contains("updated") ?? false)
    }

    func testTwoDistinctProposalsBothPost() {
        CoachNotifier.postPlanProposal(proposal())
        CoachNotifier.postPlanProposal(proposal())
        XCTAssertEqual(UpdateStore.shared.items.count, 2)
    }
}
