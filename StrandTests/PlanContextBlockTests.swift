import XCTest
@testable import Strand

/// The tool path used to send `toolModeContextNote` alone — no plan block — so the model was blind to
/// its own pending proposals exactly when `propose_plan` was callable, and re-proposed what it had
/// already proposed. W3 folds `planContextBlock()` into the tool-path context (`toolModeContext`).
///
/// Two layers are pinned: the injectable `planContextBlock(store:)` (pollution-free), and the real
/// `toolModeContext` wrapper that `send()`/`generateBrief()` actually send (via the shared store, so
/// setUp/tearDown clear it).
@MainActor
final class PlanContextBlockTests: XCTestCase {

    private func makeEngine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-plan-context-\(UUID().uuidString)"))
    }

    private var today: String { Repository.localDayKey(Date()) }

    override func setUp() {
        super.setUp()
        CoachPlanStore.shared.clearAll()
    }

    override func tearDown() {
        CoachPlanStore.shared.clearAll()
        super.tearDown()
    }

    // MARK: - The injectable core

    func testPlanBlockListsPendingProposalsSoTheModelDoesNotReProposeThem() {
        let store = CoachPlanStore(loading: false)
        store.propose(PlanProposal(day: today, sport: "Zone 2 ride", intent: .easy))

        let block = makeEngine().planContextBlock(store: store)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("AWAITING THE USER'S DECISION"))
        XCTAssertTrue(block!.contains("Zone 2 ride"))
    }

    func testPlanBlockIsNilWhenNothingIsProposedOrCommitted() {
        let store = CoachPlanStore(loading: false)
        XCTAssertNil(makeEngine().planContextBlock(store: store))
    }

    // MARK: - The real wrapper `send()` sends

    func testToolModeContextCarriesThePlanBlockWhenSomethingIsPending() {
        CoachPlanStore.shared.propose(PlanProposal(day: today, sport: "Tempo run", intent: .hard))

        let ctx = makeEngine().toolModeContext
        XCTAssertTrue(ctx.contains(AICoachEngine.toolModeContextNote),
                      "the fetch-your-numbers note must still be there")
        XCTAssertTrue(ctx.contains("AWAITING THE USER'S DECISION"),
                      "and now so is what's already on the table")
        XCTAssertTrue(ctx.contains("Tempo run"))
    }

    func testToolModeContextIsJustTheNoteWhenNothingIsPending() {
        XCTAssertEqual(makeEngine().toolModeContext, AICoachEngine.toolModeContextNote,
                       "with an empty plan store the tool-path context is exactly the note, nothing appended")
    }
}
