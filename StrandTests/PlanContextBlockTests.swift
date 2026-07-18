import XCTest
@testable import Strand

/// The tool path used to be blind to its own pending proposals exactly when `propose_plan` was
/// callable, and re-proposed what it had already proposed. W3 folded `planContextBlock()` into the
/// tool-path context (`toolModeContext`); T4 then shrank `toolModeContext` to ONLY that living plan
/// block (the stable "you have tools" prose moved to the cached system block, `toolModeClause`), so the
/// tool-path context is the plan block or empty — never a fixed note.
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
        XCTAssertTrue(ctx.contains("AWAITING THE USER'S DECISION"),
                      "what's already on the table must ride the tool-path context")
        XCTAssertTrue(ctx.contains("Tempo run"))
    }

    /// T4: the stable prose moved to the cached system block, so with nothing pending the tool-path
    /// context is EMPTY — `wirePairs` then sends the question alone, no scaffold around nothing.
    func testToolModeContextIsEmptyWhenNothingIsPending() {
        XCTAssertTrue(makeEngine().toolModeContext.isEmpty,
                      "with an empty plan store the tool-path context carries no living data at all")
    }
}
