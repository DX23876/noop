import XCTest
@testable import Strand

/// Pins the P11 card-AI plumbing: the pure prompt builders that turn a card's context into a short,
/// careful read on the cheap card model, and the pending-context state machine that a card's button
/// drives. The generation itself needs the network and isn't unit-tested; these cover everything around
/// it. @MainActor because the builders + pending state live on the @MainActor engine.
@MainActor
final class CoachCardAITests: XCTestCase {

    private func context() -> CoachCardContext {
        CoachCardContext(
            title: "Stress",
            summary: "Today's stress: 2.1 of 3 (High). Resting HR 58 bpm (+4 vs 30-day baseline).",
            suggestions: ["Why is my stress like this today?", "Should I train today?"]
        )
    }

    // MARK: - Pure prompt builders

    func testUserTurnCarriesTheCardTitleAndSummary() {
        let text = AICoachEngine.cardAnalysisUserTurn(for: context())
        XCTAssertTrue(text.contains("Stress"), "the card's title frames the request")
        XCTAssertTrue(text.contains("2.1 of 3 (High)"), "the card's own summary must reach the model verbatim")
        XCTAssertTrue(text.contains("58 bpm"))
    }

    func testSystemPromptScopesToOneMetricAndForbidsDiagnosis() {
        let text = AICoachEngine.cardAnalysisSystem(persona: .guardian)
        XCTAssertTrue(text.contains("ONE metric"), "the read is scoped to the single card")
        XCTAssertTrue(text.lowercased().contains("not a diagnosis"))
        XCTAssertTrue(text.contains("never invent data"), "grounding: no numbers beyond what it's given")
    }

    func testSystemPromptCarriesThePersonaVoice() {
        // The persona preamble leads the card system prompt, so a card read sounds like the chosen coach.
        let text = AICoachEngine.cardAnalysisSystem(persona: .commander)
        XCTAssertTrue(text.hasPrefix(CoachPersona.commander.systemPreamble),
                      "the persona's voice must lead the card-analysis system prompt")
    }

    // MARK: - Pending-context state machine

    private func makeEngine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-card-ai-\(UUID().uuidString)"))
    }

    func testOpenedFromCardArmsThePendingContext() {
        let engine = makeEngine()
        XCTAssertNil(engine.pendingCardContext)
        engine.openedFromCard(context())
        XCTAssertEqual(engine.pendingCardContext?.title, "Stress")
    }

    func testRunCardAnalysisClearsThePendingContextEvenWhenNotConfigured() async {
        // An unconfigured coach can't generate, but the pending context must still be consumed so a later
        // plain open doesn't silently re-fire a stale card read.
        let engine = makeEngine()
        engine.openedFromCard(context())
        await engine.runCardAnalysisIfNeeded()
        XCTAssertNil(engine.pendingCardContext, "the pending context is consumed on the first run")
        XCTAssertTrue(engine.messages.isEmpty, "no message is produced without a connected provider")
    }
}
