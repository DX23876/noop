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
        // Reset via the setter (its didSet owns the private UserDefaults key) rather than a hardcoded
        // string, so a test that flips allowEmoji never leaks into the next test's default-off premise.
        AICoachEngine(repo: Repository(deviceId: "cleanup-\(UUID().uuidString)")).allowEmoji = false
        super.tearDown()
    }

    // MARK: - No tools → no promise

    /// Custom deliberately has no ToolCallingClient conformance, so `tools:` is always `[]` for it —
    /// tool support on a local server depends on both the server and the model, and many local models
    /// fail silently or emit malformed JSON rather than a clean error. (Gemini filled this role until
    /// it gained tools; Custom is now the only provider that genuinely cannot run them.)
    func testProposePlanIsNeverPromisedWhenToolCallingIsOff() {
        let engine = makeEngine()
        engine.provider = .custom
        engine.dataConsent = true
        XCTAssertFalse(engine.toolCallingActive, "premise: Custom cannot run tools")
        XCTAssertFalse(engine.systemPrompt.contains("propose_plan"),
                       "the model must not be told to call a tool it was never handed")
    }

    /// The sentence that actually stops the reported bug: the coach claiming it noted something.
    func testTheNoToolClauseForbidsClaimingSomethingWasRecorded() {
        let engine = makeEngine()
        engine.provider = .custom
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
        engine.provider = .custom
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
        engine.provider = .custom
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

    // MARK: - P12: the citation clause rides EVERY prompt

    /// Explainability (#P12 12.3): unlike the tool clauses, the citation discipline is universal — it
    /// must be present whether or not tools are live, so the coach names its source in both modes.
    func testCitationClauseIsPresentWithTools() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.dataConsent = true
        XCTAssertTrue(engine.toolCallingActive)
        XCTAssertTrue(engine.systemPrompt.contains(AICoachEngine.citationClause))
    }

    func testCitationClauseIsPresentWithoutTools() {
        let engine = makeEngine()
        engine.provider = .custom
        engine.dataConsent = true
        XCTAssertFalse(engine.toolCallingActive)
        XCTAssertTrue(engine.systemPrompt.contains(AICoachEngine.citationClause),
                      "the source-citation rule is universal, not gated on tools")
    }

    func testCitationClauseSurvivesACustomSystemPromptOverride() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.dataConsent = true
        engine.customSystemPrompt = "Be brief."
        XCTAssertTrue(engine.systemPrompt.contains(AICoachEngine.citationClause),
                      "a custom prompt must not drop the citation discipline")
    }

    // MARK: - P13: the coach-voice clause rides every prompt

    /// The human/careful register (#P13 7.2) is universal like the citation clause — present with or
    /// without tools, and unstrippable by a custom prompt.
    func testVoiceClauseIsPresentInBothModes() {
        let withTools = makeEngine()
        withTools.provider = .anthropic; withTools.dataConsent = true
        XCTAssertTrue(withTools.toolCallingActive)
        XCTAssertTrue(withTools.systemPrompt.contains(AICoachEngine.voiceClause))

        let withoutTools = makeEngine()
        withoutTools.provider = .custom; withoutTools.dataConsent = true
        XCTAssertFalse(withoutTools.toolCallingActive)
        XCTAssertTrue(withoutTools.systemPrompt.contains(AICoachEngine.voiceClause))
    }

    func testVoiceClauseSurvivesACustomSystemPromptOverride() {
        let engine = makeEngine()
        engine.provider = .anthropic; engine.dataConsent = true
        engine.customSystemPrompt = "Be brief."
        XCTAssertTrue(engine.systemPrompt.contains(AICoachEngine.voiceClause))
    }

    // MARK: - P14: the emoji clause matches the user's dial and rides every prompt

    func testEmojiOffByDefaultForbidsEmoji() {
        let engine = makeEngine()
        XCTAssertFalse(engine.allowEmoji, "off by default, matching the P13 careful-voice register")
        XCTAssertEqual(engine.emojiClause, AICoachEngine.emojiOffClause)
        XCTAssertTrue(engine.systemPrompt.contains(AICoachEngine.emojiOffClause))
    }

    func testEmojiOnUsesTheOnClause() {
        let engine = makeEngine()
        engine.allowEmoji = true
        XCTAssertEqual(engine.emojiClause, AICoachEngine.emojiOnClause)
        XCTAssertTrue(engine.systemPrompt.contains(AICoachEngine.emojiOnClause))
        XCTAssertFalse(engine.systemPrompt.contains(AICoachEngine.emojiOffClause),
                       "the two emoji clauses are mutually exclusive")
    }

    func testEmojiClauseIsPresentInBothToolModes() {
        let withTools = makeEngine()
        withTools.provider = .anthropic; withTools.dataConsent = true
        XCTAssertTrue(withTools.systemPrompt.contains(AICoachEngine.emojiOffClause))

        let withoutTools = makeEngine()
        withoutTools.provider = .custom; withoutTools.dataConsent = true
        XCTAssertTrue(withoutTools.systemPrompt.contains(AICoachEngine.emojiOffClause))
    }

    func testEmojiClauseSurvivesACustomSystemPromptOverride() {
        let engine = makeEngine()
        engine.provider = .anthropic; engine.dataConsent = true
        engine.customSystemPrompt = "Be brief."
        XCTAssertTrue(engine.systemPrompt.contains(AICoachEngine.emojiOffClause))
    }
}
