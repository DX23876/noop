import XCTest
@testable import Strand

/// The coach must never promise a tool it wasn't handed.
///
/// `send()` passes `tools: toolCallingActive ? coachTools : []`, but the system prompt used to say
/// "record it with propose_plan" unconditionally. For a provider without tool-calling — or with data
/// consent off — the model was told to record proposals via a tool that wasn't on the wire, and would
/// report having done so. Nothing was created, so the user had nothing to accept: the proposal never
/// existed. These pin that the promise and the tool array always agree.
@MainActor
final class CoachSystemPromptToolClauseTests: XCTestCase {

    private func makeEngine() -> AICoachEngine {
        UserDefaults.standard.removeObject(forKey: AICoachEngine.systemPromptKey)
        UserDefaults.standard.removeObject(forKey: CoachPersona.defaultsKey)
        return AICoachEngine(repo: Repository(deviceId: "test-tool-clause-\(UUID().uuidString)"))
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AICoachEngine.systemPromptKey)
        UserDefaults.standard.removeObject(forKey: CoachPersona.defaultsKey)
        super.tearDown()
    }

    // MARK: - No tools → no promise

    /// Gemini deliberately has no ToolCallingClient conformance, so `tools:` is always `[]` for it.
    func testProposePlanIsNeverPromisedWhenToolCallingIsOff() {
        let engine = makeEngine()
        engine.provider = .gemini
        engine.dataConsent = true
        XCTAssertFalse(engine.toolCallingActive, "premise: Gemini cannot run tools")
        XCTAssertFalse(engine.systemPrompt.contains("propose_plan"),
                       "the model must not be told to call a tool it was never handed")
    }

    /// The sentence that actually stops the reported bug: the coach claiming it noted something.
    func testTheNoToolClauseForbidsClaimingSomethingWasRecorded() {
        let engine = makeEngine()
        engine.provider = .gemini
        engine.dataConsent = true
        XCTAssertTrue(engine.systemPrompt.contains("Never claim you've noted"))
    }

    /// `toolCallingActive` gates on consent too — no consent, no tools, so no promise either.
    func testWithoutDataConsentThePromiseIsAlsoAbsent() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.dataConsent = false
        XCTAssertFalse(engine.toolCallingActive, "premise: no consent means no tools")
        XCTAssertFalse(engine.systemPrompt.contains("propose_plan"))
    }

    // MARK: - Tools → the promise is there

    func testProposePlanIsPromisedWhenToolCallingIsOn() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.dataConsent = true
        XCTAssertTrue(engine.toolCallingActive, "premise: Anthropic + consent runs tools")
        XCTAssertTrue(engine.systemPrompt.contains("propose_plan"))
        XCTAssertFalse(engine.systemPrompt.contains("Never claim you've noted"),
                       "the no-tool clause must not ride along when tools are live")
    }

    // MARK: - The custom-prompt hole

    /// A user with a `ai.systemPrompt` override used to lose the plan rule entirely (it lived inside
    /// `defaultSystemPrompt`, which an override replaces wholesale). Appending it in `systemPrompt`
    /// means an override can no longer strip it — nor get the wrong one.
    func testACustomSystemPromptStillCarriesTheCorrectClause() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.dataConsent = true
        engine.customSystemPrompt = "Be brief."

        XCTAssertTrue(engine.systemPrompt.contains("Be brief."), "premise: the override is in effect")
        XCTAssertTrue(engine.systemPrompt.contains("propose_plan"),
                      "a custom prompt must not silently drop the plan rule")
    }

    func testACustomSystemPromptCannotAcquireThePromiseWithoutTools() {
        let engine = makeEngine()
        engine.provider = .gemini
        engine.dataConsent = true
        engine.customSystemPrompt = "Be brief."
        XCTAssertFalse(engine.systemPrompt.contains("propose_plan"))
        XCTAssertTrue(engine.systemPrompt.contains("Never claim you've noted"))
    }

    // MARK: - Regression nail

    /// Cheap guard against someone re-adding the sentence to the default, which would reintroduce the
    /// unconditional promise the clause split exists to remove.
    func testTheDefaultPromptTextItselfNeverMentionsProposePlan() {
        XCTAssertFalse(AICoachEngine.defaultSystemPrompt.contains("propose_plan"),
                       "the plan rule belongs in planToolClause, which is applied conditionally")
        XCTAssertFalse(AICoachEngine.defaultSystemPrompt.contains("get_session_outlook"))
        // The tone half must stay unconditional — it is true whether or not tools exist.
        XCTAssertTrue(AICoachEngine.defaultSystemPrompt.contains("Plans are AGREED, not issued"))
        XCTAssertTrue(AICoachEngine.defaultSystemPrompt.contains("not a failure"))
    }

    // MARK: - T4: the tool-awareness map (toolModeClause) rides the cached system block

    /// The four-verb map is present EXACTLY when tools are live — the same gate as the plan clause, so
    /// the model is never told about tools it wasn't handed.
    func testToolModeClauseIsPresentWhenToolCallingIsOn() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.dataConsent = true
        XCTAssertTrue(engine.toolCallingActive)
        XCTAssertTrue(engine.systemPrompt.contains(AICoachEngine.toolModeClause))
    }

    func testToolModeClauseIsAbsentWhenToolCallingIsOff() {
        let engine = makeEngine()
        engine.provider = .gemini
        engine.dataConsent = true
        XCTAssertFalse(engine.toolCallingActive)
        XCTAssertFalse(engine.systemPrompt.contains(AICoachEngine.toolModeClause))
        // Mutually exclusive with the no-tool clause: they never both ride the same prompt.
        XCTAssertTrue(engine.systemPrompt.contains(AICoachEngine.noPlanToolClause))
    }

    /// The regression the W1 clause split exists for: a user with a custom `ai.systemPrompt` override
    /// used to lose mode-specific rules entirely (they lived inside `defaultSystemPrompt`, which an
    /// override replaces wholesale). Because `toolModeClause` is APPENDED in `systemPrompt`, an override
    /// can't strip it.
    func testToolModeClauseSurvivesACustomSystemPromptOverride() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.dataConsent = true
        engine.customSystemPrompt = "Be brief."
        XCTAssertTrue(engine.systemPrompt.contains("Be brief."), "premise: the override is in effect")
        XCTAssertTrue(engine.systemPrompt.contains(AICoachEngine.toolModeClause),
                      "a custom prompt must not silently drop the tool-awareness map")
    }
}
