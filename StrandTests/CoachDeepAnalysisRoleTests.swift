import XCTest
@testable import Strand

/// The "Look at this more closely" re-run.
///
/// Depth is modelled as a MODEL, not as a reasoning/thinking flag, and these tests pin the consequences
/// of that choice. With free model choice (OpenRouter fronts 300+), a reasoning parameter is ignored by
/// roughly half of them, so the same switch would deepen one model and do nothing for the next —
/// unexplainable behaviour. A second model differs on every provider, including those with no reasoning
/// support at all.
///
/// The other half of the design is cost: the deep model is opt-in, per question, and never sticky.
@MainActor
final class CoachDeepAnalysisRoleTests: XCTestCase {

    private func makeEngine() -> AICoachEngine {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-deep-\(UUID().uuidString)"))
        engine.deepModel = ""
        // `messages` writes through the ACTIVE conversation and is a silent no-op without one.
        engine.newConversation()
        return engine
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ai.deepModel")
        super.tearDown()
    }

    // MARK: - Off by default

    func testNoBuiltInDefaultForAnyProvider() {
        for provider in AIProvider.allCases {
            XCTAssertTrue(provider.defaultModel(for: .deepAnalysis).isEmpty,
                          "\(provider.rawValue): which model is worth its price is the user's call — "
                          + "defaulting one silently moves questions onto a model they never chose")
        }
    }

    func testFeatureIsHiddenUntilAModelIsChosen() {
        let engine = makeEngine()
        XCTAssertFalse(engine.hasDeepAnalysisModel)

        engine.deepModel = "anthropic/claude-opus-4.8"
        XCTAssertTrue(engine.hasDeepAnalysisModel)
    }

    func testWhitespaceOnlyIsStillUnset() {
        let engine = makeEngine()
        engine.deepModel = "   "
        XCTAssertFalse(engine.hasDeepAnalysisModel,
                       "a stray space must not switch on a cost-multiplying feature")
    }

    func testDeepRerunIsANoOpWithoutAModel() {
        let engine = makeEngine()
        engine.regenerateDeeply()
        XCTAssertFalse(engine.deepTurn,
                       "re-running the same model returns the same answer and bills for it twice")
    }

    // MARK: - Routing

    func testRequestModelIsTheChatModelByDefault() {
        let engine = makeEngine()
        engine.model = "openai/gpt-4o"
        XCTAssertEqual(engine.requestModel, "openai/gpt-4o")
    }

    func testDeepModelResolvesThroughTheRoleResolver() {
        let engine = makeEngine()
        engine.model = "openai/gpt-4o-mini"
        engine.deepModel = "anthropic/claude-opus-4.8"

        XCTAssertEqual(engine.model(for: .deepAnalysis), "anthropic/claude-opus-4.8")
        XCTAssertEqual(engine.model(for: .chat), "openai/gpt-4o-mini",
                       "the ordinary chat model is untouched by the deep setting")
    }

    func testRoleFallsBackToTheChatModelRatherThanEmpty() {
        let engine = makeEngine()
        engine.model = "openai/gpt-4o"
        XCTAssertEqual(engine.model(for: .deepAnalysis), "openai/gpt-4o",
                       "callers gate on hasDeepAnalysisModel, but the resolver must never return \"\"")
    }

    // MARK: - Cost: the flag is per question, never a mode

    func testDeepTurnArmsOnlyForTheRequestedRerun() {
        let engine = makeEngine()
        engine.deepModel = "anthropic/claude-opus-4.8"
        engine.messages = [ChatMessage(role: .user, text: "Wie war meine Woche?"),
                           ChatMessage(role: .assistant, text: "Solide.")]

        engine.regenerateDeeply()
        XCTAssertTrue(engine.deepTurn)
        XCTAssertEqual(engine.requestModel, "anthropic/claude-opus-4.8",
                       "the armed turn actually routes to the heavier model")

        engine.stop()
        XCTAssertFalse(engine.deepTurn, "depth is asked for per question — a sticky mode would make a "
                       + "whole chat silently dearer")
        XCTAssertEqual(engine.requestModel, engine.model)
    }

    /// A deep run with nothing to resend must not leave the flag armed for whatever the user types next.
    func testFlagIsDisarmedWhenThereIsNothingToResend() {
        let engine = makeEngine()
        engine.deepModel = "anthropic/claude-opus-4.8"
        engine.messages = []

        engine.regenerateDeeply()
        XCTAssertFalse(engine.deepTurn)
    }

    // MARK: - The window follows the model actually used

    func testHistoryBudgetFollowsTheDeepModel() {
        let engine = makeEngine()
        engine.provider = .custom
        engine.model = "some-local-7b"          // unknown ⇒ conservative
        engine.deepModel = "claude-opus-4.8"    // known large window

        XCTAssertEqual(CoachHistoryBudget.tokens(provider: .custom, model: engine.requestModel),
                       CoachHistoryBudget.conservativeTokens)

        engine.messages = [ChatMessage(role: .user, text: "x"), ChatMessage(role: .assistant, text: "y")]
        engine.regenerateDeeply()

        XCTAssertEqual(CoachHistoryBudget.tokens(provider: .custom, model: engine.requestModel),
                       CoachHistoryBudget.spaciousTokens,
                       "the window has to match the model the request is actually sent to")
    }
}
