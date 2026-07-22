import XCTest
@testable import Strand
import WhoopProtocol
import StrandAnalytics

/// Covers the two small AI-Coach additions:
///   1. The editable system prompt — persisted in UserDefaults under `AICoachEngine.systemPromptKey`,
///      read FRESH per request via `systemPrompt`, with a Reset-to-default that clears the override.
///   2. The derived Baevsky Stress Index context line — its pure formatter (`stressIndexSummary`) and
///      that the line uses the SAME `StressIndex.stressIndex(rr:)` computation StressView does.
///
/// Both paths are UserDefaults / pure — no network, no Keychain — so they run headlessly.
@MainActor
final class AICoachPromptAndStressTests: XCTestCase {

    /// A fresh engine plus a clean slate: clear the prompt key AND the persona key before and after so
    /// tests don't leak — `systemPrompt` prepends `persona.systemPreamble` (added after this file was
    /// first written), and personas default to `.friend`, not an empty preamble, so a persona choice
    /// left over from another test (or a real run of the app sharing the same UserDefaults.standard)
    /// would otherwise silently change what "the default prompt" means here.
    private func makeEngine() -> AICoachEngine {
        UserDefaults.standard.removeObject(forKey: AICoachEngine.systemPromptKey)
        UserDefaults.standard.removeObject(forKey: CoachPersona.defaultsKey)
        return AICoachEngine(repo: Repository(deviceId: "test-aicoach-prompt"))
    }

    /// What `systemPrompt` assembles around a given base: the persona's voice preamble in front, and the
    /// plan-tool clause behind (the clause is conditional on `toolCallingActive`, so it's read off the
    /// engine rather than assumed). `defaultSystemPrompt` alone is never what gets sent — asserting
    /// equality against it directly, as this file originally did, cannot pass once either wrapper exists.
    /// These tests are about which BASE is chosen (default vs. override); the wrappers are assembled the
    /// same way here so that equality still pins exactly that.
    private func expectedPrompt(base: String, engine: AICoachEngine) -> String {
        let clause = engine.toolCallingActive ? AICoachEngine.planToolClause : AICoachEngine.noPlanToolClause
        // R9: the identity clause (name + tone) leads, ahead of the persona STYLE preamble.
        var prompt = CoachIdentityStore.shared.identity.identityPreamble + "\n\n"
            + CoachPersona.current.systemPreamble + "\n\n" + base + "\n\n" + clause
        // T4: the tool-awareness map rides the cached system block under the same tool-calling gate.
        if engine.toolCallingActive { prompt += "\n\n" + AICoachEngine.toolModeClause }
        // P12: the citation clause rides EVERY prompt, appended last (both modes).
        prompt += "\n\n" + AICoachEngine.citationClause
        // P13: the coach-voice clause rides every prompt too, after the citation clause.
        prompt += "\n\n" + AICoachEngine.voiceClause
        // Reply-language clause: read fresh from the engine (Locale.current) so this reconstruction
        // matches the real `systemPrompt` exactly — it sits after the voice clause, before emoji.
        prompt += "\n\n" + engine.languageClause
        // P14: the emoji clause, matching the engine's current allowEmoji setting.
        prompt += "\n\n" + engine.emojiClause
        return prompt
    }

    private func expectedDefaultPrompt(_ engine: AICoachEngine) -> String {
        expectedPrompt(base: AICoachEngine.defaultSystemPrompt, engine: engine)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AICoachEngine.systemPromptKey)
        UserDefaults.standard.removeObject(forKey: CoachPersona.defaultsKey)
        super.tearDown()
    }

    // MARK: - Feature 1: editable system prompt

    func testDefaultsToBuiltInPromptWhenNothingStored() {
        let engine = makeEngine()
        XCTAssertEqual(engine.systemPrompt, expectedDefaultPrompt(engine))
        XCTAssertFalse(engine.hasCustomSystemPrompt)
    }

    func testEditPersistsAndIsReadFreshOnNextSend() {
        let engine = makeEngine()
        let custom = "You are a terse cycling coach. Answer in two sentences."
        engine.customSystemPrompt = custom

        // Persisted under the documented key, and surfaced by the fresh-read property. The persona
        // preamble still rides on top of a CUSTOM prompt too — only the methodology underneath changes.
        XCTAssertEqual(UserDefaults.standard.string(forKey: AICoachEngine.systemPromptKey), custom)
        XCTAssertEqual(engine.systemPrompt, expectedPrompt(base: custom, engine: engine))
        XCTAssertTrue(engine.hasCustomSystemPrompt)

        // "Read fresh per send" — a write straight to UserDefaults (as another session might) is
        // picked up by the next `systemPrompt` read without rebuilding the engine.
        let edited = custom + " Always cite a number."
        UserDefaults.standard.set(edited, forKey: AICoachEngine.systemPromptKey)
        XCTAssertEqual(engine.systemPrompt, expectedPrompt(base: edited, engine: engine))
    }

    func testResetRestoresDefaultAndClearsTheKey() {
        let engine = makeEngine()
        engine.customSystemPrompt = "Custom override."
        XCTAssertTrue(engine.hasCustomSystemPrompt)

        engine.resetSystemPrompt()
        XCTAssertNil(UserDefaults.standard.string(forKey: AICoachEngine.systemPromptKey))
        XCTAssertEqual(engine.systemPrompt, expectedDefaultPrompt(engine))
        XCTAssertFalse(engine.hasCustomSystemPrompt)
    }

    func testBlankOverrideNeverSendsAnEmptyPrompt() {
        let engine = makeEngine()
        engine.customSystemPrompt = "   \n  "   // whitespace only
        // A blank override clears the key, so the default is sent — never an empty system prompt.
        XCTAssertNil(UserDefaults.standard.string(forKey: AICoachEngine.systemPromptKey))
        XCTAssertEqual(engine.systemPrompt, expectedDefaultPrompt(engine))
        XCTAssertFalse(engine.hasCustomSystemPrompt)
    }

    // MARK: - The morning brief instruction (W5)

    /// With tools live, part (2) must require a structured proposal — that's what turns the brief's prose
    /// into an acceptable session on Today.
    func testBriefAsksForAProposalWhenToolsAreActive() {
        let instruction = AICoachEngine.briefInstruction(toolsActive: true)
        XCTAssertTrue(instruction.contains("propose_plan"))
    }

    /// The first line of defence against duplicate proposals (the other two are the plan block on the
    /// tool path and the store-side dedup).
    func testBriefAsksForExactlyOneSession() {
        let instruction = AICoachEngine.briefInstruction(toolsActive: true)
        XCTAssertTrue(instruction.contains("exactly ONE"))
    }

    /// Without tools the brief must not name propose_plan — the honesty counterpart of W1: point the
    /// user at Your plan instead of pretending to have recorded anything.
    func testBriefWithoutToolsTellsTheUserToAddItThemselves() {
        let instruction = AICoachEngine.briefInstruction(toolsActive: false)
        XCTAssertFalse(instruction.contains("propose_plan"),
                       "must not promise a tool that isn't on the wire")
        XCTAssertTrue(instruction.contains("Your plan"))
    }

    /// Golden string for the non-tool path. `buildFullContext()` genuinely puts charge/HRV/rest/readiness
    /// in the message there, so "Based on the data above" stays true. Pinned byte-for-byte; updated in P9
    /// to carry intensity + duration and a low-readiness alternative (9.2/9.3) while keeping the shape.
    func testBriefWithoutToolsGoldenString() {
        let instruction = AICoachEngine.briefInstruction(toolsActive: false)
        XCTAssertEqual(instruction, """
        Based on the data above, give me TODAY'S coaching brief — kept tight, no preamble, three \
        short parts: \
        (1) my readiness in one line, citing charge, HRV and rest; \
        (2) exactly what to do today — the activity, its intensity, and a rough duration — and what \
        to avoid. If my readiness is low, make it the easy/short option (or rest) and say so plainly. \
        You cannot record it for me, so close by telling me to add it in Your plan if I want it; \
        (3) one specific thing to improve my charge. Be punchy and motivating — not long.
        """)
    }

    /// #P9 9.2: both branches now ask for the session's intensity and a rough duration, plus a lighter
    /// option when readiness is low — the difference between "train" and an actionable prescription.
    func testBriefAsksForIntensityDurationAndALowReadinessAlternative() {
        for active in [true, false] {
            let instruction = AICoachEngine.briefInstruction(toolsActive: active)
            XCTAssertTrue(instruction.contains("intensity"), "brief must prescribe intensity")
            XCTAssertTrue(instruction.contains("duration"), "brief must give a rough duration")
            XCTAssertTrue(instruction.lowercased().contains("readiness is low"),
                          "brief must offer a lighter option on a low day")
        }
    }

    /// T1's actual fix: on the tool path there IS no data above (toolModeContext carries no numbers), so
    /// the brief must not claim there is, and must tell the model how to get real ones instead.
    func testBriefWithToolsDoesNotClaimDataItWasNotGiven() {
        let instruction = AICoachEngine.briefInstruction(toolsActive: true)
        XCTAssertFalse(instruction.contains("Based on the data above"),
                       "the tool path is given no numbers, so it must not claim it was")
    }

    func testBriefWithToolsNamesTheReadTools() {
        let instruction = AICoachEngine.briefInstruction(toolsActive: true)
        XCTAssertTrue(instruction.contains("get_readiness"))
        XCTAssertTrue(instruction.contains("get_biometric_summary"))
    }

    /// Both variants still deliver the three-part brief the check-in notification promises.
    func testBothVariantsKeepTheThreePartShape() {
        for active in [true, false] {
            let instruction = AICoachEngine.briefInstruction(toolsActive: active)
            XCTAssertTrue(instruction.contains("(1)"))
            XCTAssertTrue(instruction.contains("(2)"))
            XCTAssertTrue(instruction.contains("(3)"))
        }
    }

    // MARK: - Feature 2: derived stress line

    func testStressIndexSummaryFormatsOneRoundedNumber() {
        // The line carries exactly the rounded SI plus the labelled proxy note — a derived summary.
        let line = AICoachEngine.stressIndexSummary(si: 223.82920110192836)
        XCTAssertTrue(line.hasPrefix("Stress (SI): 224 "), "rounds and labels the SI: \(line)")
        XCTAssertTrue(line.contains("Baevsky Stress Index"))
        // No raw R-R reading leaks into the summary — it's a single derived number only.
        XCTAssertFalse(line.contains("700"))
        XCTAssertFalse(line.contains("ms"), "no raw R-R values in the summary line")
    }

    func testSummaryNumberMatchesStressViewComputation() {
        // The SAME 22-beat golden series StressIndexTests pins (SI ≈ 223.83 → rounds to 224). The coach
        // line must report the value `StressIndex.stressIndex(rr:)` produces — the exact StressView path.
        let raw: [Double] = [700, 720, 740, 760, 780, 800, 820, 840, 860, 800, 800,
                             800, 800, 820, 780, 800, 810, 790, 800, 800, 805, 795]
        let rr = raw.enumerated().map { RRInterval(ts: 1000 + $0.offset, rrMs: Int($0.element)) }
        let si = StressIndex.stressIndex(rr: rr)
        XCTAssertNotNil(si)
        let expected = "Stress (SI): \(Int(si!.rounded())) "
        XCTAssertTrue(AICoachEngine.stressIndexSummary(si: si!).hasPrefix(expected))
    }
}
