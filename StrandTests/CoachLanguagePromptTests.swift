import XCTest
@testable import Strand

/// Nothing in `systemPrompt` used to say what language to reply in, so the coach defaulted to English
/// regardless of the app's own (fully localized) language — a user running NOOP in German or Japanese
/// still got English chat replies, check-ins and briefs. `languageClause` closes that: it names the
/// app's current language (from `Locale.current`, the same source every formatter in the app already
/// reads) and rides every prompt, universal like the citation/voice clauses.
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

    /// The English name resolved the SAME way `languageClause` resolves it — pins the mechanism (a real
    /// lookup from the current language code, not a hardcoded "English") independent of whatever locale
    /// happens to be running the test.
    private var expectedLanguageName: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? "English"
    }

    func testLanguageClauseNamesTheCurrentAppLanguage() {
        let engine = makeEngine()
        XCTAssertTrue(engine.languageClause.contains(expectedLanguageName))
        XCTAssertTrue(engine.languageClause.lowercased().contains("reply in"))
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
}
