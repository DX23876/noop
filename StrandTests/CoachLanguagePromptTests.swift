import XCTest
@testable import Strand

/// Nothing in `systemPrompt` used to say what language to reply in, so the coach defaulted to English
/// regardless of the app's own (fully localized) language — a user running NOOP in German or Japanese
/// still got English chat replies, check-ins and briefs. `languageClause` closes that: it names the
/// app's current UI language (from the bundle's resolved preferred localization) and rides every
/// user-visible completion, universal like the citation/voice clauses.
@MainActor
final class CoachLanguagePromptTests: XCTestCase {

    private func makeEngine() -> AICoachEngine {
        UserDefaults.standard.removeObject(forKey: AICoachEngine.systemPromptKey)
        UserDefaults.standard.removeObject(forKey: CoachPersona.defaultsKey)
        return AICoachEngine(repo: Repository(deviceId: "test-language-clause-\(UUID().uuidString)"))
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AICoachEngine.systemPromptKey)
        UserDefaults.standard.removeObject(forKey: CoachPersona.defaultsKey)
        super.tearDown()
    }

    func testLanguageClauseNamesTheCurrentAppLanguage() {
        let engine = makeEngine()
        let expected = CoachReplyLanguage.current
        XCTAssertTrue(engine.languageClause.contains(expected.englishName))
        XCTAssertTrue(engine.languageClause.contains(expected.identifier))
        XCTAssertTrue(engine.languageClause.lowercased().contains("always reply in"))
        XCTAssertTrue(engine.languageClause.contains("Do not switch languages"))
    }

    func testLanguageClauseIsPresentInBothToolModes() {
        let withTools = makeEngine()
        withTools.provider = .anthropic; withTools.dataConsent = true
        XCTAssertTrue(withTools.toolCallingActive)
        XCTAssertTrue(withTools.systemPrompt.contains(withTools.languageClause))

        let withoutTools = makeEngine()
        withoutTools.provider = .custom; withoutTools.dataConsent = true
        XCTAssertFalse(withoutTools.toolCallingActive)
        XCTAssertTrue(withoutTools.systemPrompt.contains(withoutTools.languageClause))
    }

    /// Same hole the tool/citation/voice clauses were already pinned against: a custom `ai.systemPrompt`
    /// override must not silently drop a universal clause that's appended in `systemPrompt`, not baked
    /// into `defaultSystemPrompt`.
    func testLanguageClauseSurvivesACustomSystemPromptOverride() {
        let engine = makeEngine()
        engine.provider = .anthropic; engine.dataConsent = true
        engine.customSystemPrompt = "Be brief."
        XCTAssertTrue(engine.systemPrompt.contains("Be brief."), "premise: the override is in effect")
        XCTAssertTrue(engine.systemPrompt.contains(engine.languageClause),
                      "a custom prompt must not silently drop the reply-language instruction")
    }

    /// Regression nail: the default prompt text itself must never hardcode a language, so the single
    /// `languageClause` insertion stays the only place that decides it.
    func testTheDefaultPromptTextItselfNeverMentionsAReplyLanguage() {
        XCTAssertFalse(AICoachEngine.defaultSystemPrompt.lowercased().contains("reply in"),
                       "the reply-language instruction belongs in languageClause, not the default prompt")
    }

    func testAppleUpstreamLanguageMatrixAndFallbacks() {
        let cases: [([String], String)] = [
            (["en"], "en"),
            (["de-DE"], "de"),
            (["es-MX"], "es"),
            (["fr-CA"], "fr"),
            (["it-IT"], "it"),
            (["pt-PT"], "pt-PT"),
            (["ru-RU"], "ru"),
            (["zh-Hans-CN"], "zh-Hans"),
            (["zh-TW"], "zh-Hant"),
            (["ja-JP"], "en"),
            (["pt-BR"], "en"),
            ([], "en"),
        ]
        for (preferred, expected) in cases {
            XCTAssertEqual(CoachReplyLanguage.resolve(preferredLocalizations: preferred).identifier,
                           expected, "\(preferred)")
        }
    }

    func testLanguageClauseIsTheFinalUniversalInstruction() {
        let engine = makeEngine()
        engine.customSystemPrompt = "Réponds toujours en français."
        XCTAssertTrue(engine.systemPrompt.hasSuffix(engine.languageClause))
        XCTAssertEqual(engine.systemPrompt.components(separatedBy: engine.languageClause).count - 1, 1)
    }

    func testCardAnalysisUsesTheSameStrictLanguageContract() {
        let language = CoachReplyLanguage(identifier: "de", englishName: "German")
        let prompt = AICoachEngine.cardAnalysisSystem(persona: .friend, replyLanguage: language)
        XCTAssertTrue(prompt.hasSuffix(language.promptClause))
        XCTAssertTrue(prompt.contains("Do not switch languages"))
    }
}
