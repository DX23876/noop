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

    /// #P7 9.8: a session the USER planned themselves is marked as theirs in the context, so the coach
    /// comments on the routine instead of re-pitching it as its own idea. And the committed list tells
    /// the model not to re-propose any of them.
    func testPlanBlockMarksAUserRoutineAsTheirOwnAndForbidsReProposing() {
        let store = CoachPlanStore(loading: false)
        store.addUserSession(day: today, time: nil, sport: "Morning run", intent: .easy)

        let block = makeEngine().planContextBlock(store: store)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("do NOT propose any of these again"),
                      "committed sessions must be marked off-limits for a fresh proposal")
        XCTAssertTrue(block!.contains("the user's own session"),
                      "a user-created routine must be flagged as theirs, not the coach's idea")
        XCTAssertTrue(block!.contains("Morning run"))
    }

    // MARK: - The real wrapper `send()` sends

    func testToolModeContextCarriesThePlanBlockWhenSomethingIsPending() {
        CoachPlanStore.shared.propose(PlanProposal(day: today, sport: "Tempo run", intent: .hard))

        let ctx = makeEngine().toolModeContext
        XCTAssertTrue(ctx.contains("AWAITING THE USER'S DECISION"),
                      "what's already on the table must ride the tool-path context")
        XCTAssertTrue(ctx.contains("Tempo run"))
    }

    /// T4: the stable prose stays in the CACHED system block, so with nothing pending the tool-path
    /// context carries no plan scaffold — `wirePairs` doesn't wrap a "Question:" frame around nothing.
    ///
    /// It is no longer empty, and deliberately so: the clock and the recent-thread index live here now.
    /// Both are per-request LIVING data — exactly what this path is for — and both were absent, which is
    /// what made "what did I ask you yesterday?" unanswerable (see `CoachConversationRecallTests`). The
    /// invariant being pinned is "no stable prose, no empty scaffold", not "empty".
    func testToolModeContextCarriesNoPlanScaffoldWhenNothingIsPending() {
        let ctx = makeEngine().toolModeContext
        XCTAssertFalse(ctx.contains("AWAITING THE USER'S DECISION"),
                       "no pending proposal means no plan block")
        XCTAssertFalse(ctx.contains("do NOT propose any of these again"))
    }

    /// The stable "you have tools, fetch before advising" prose must stay in the cached system block. If
    /// it leaked back into the per-turn context it would be re-sent uncached on every tool round.
    func testStableToolProseStaysInTheCachedSystemBlock() {
        let engine = makeEngine()
        XCTAssertFalse(engine.toolModeContext.contains(AICoachEngine.toolModeClause),
                       "re-sending the tool-awareness map per round is what caching exists to avoid")
    }
}
