import XCTest
@testable import Strand

/// Which question the app is answering.
///
/// A second question supersedes the first. `startSend` cancels it, but cancellation is cooperative: the
/// superseded turn keeps running to its next suspension point and then runs its own cleanup, which used
/// to turn off the spinner the new turn had just turned on, discard the new turn's pending charts,
/// clear its deep flag and present its own failure as if the live question had failed.
///
/// These assert the RESOLVER rather than counting its gated call sites: a count passes while a fourth
/// reader decides for itself who the live turn is, which is the failure mode the house rules name.
@MainActor
final class CoachTurnOwnershipTests: XCTestCase {

    private func makeEngine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-turn-\(UUID().uuidString)"))
    }

    func testTheTurnJustBegunIsTheLiveOne() {
        let engine = makeEngine()
        let turn = engine.beginTurn()
        XCTAssertTrue(engine.isLiveTurn(turn))
    }

    func testASupersededTurnIsNoLongerTheLiveOne() {
        let engine = makeEngine()
        let first = engine.beginTurn()
        let second = engine.beginTurn()

        XCTAssertFalse(engine.isLiveTurn(first),
                       "the first question has been replaced and owns no shared state any more")
        XCTAssertTrue(engine.isLiveTurn(second))
    }

    /// Two engines must not be able to answer for each other's turn: the id says which question, and
    /// the engine says whose.
    func testATurnFromAnotherEngineIsNeverLiveHere() {
        let engine = makeEngine()
        let elsewhere = makeEngine().beginTurn()
        _ = engine.beginTurn()

        XCTAssertFalse(engine.isLiveTurn(elsewhere))
    }
}
