import XCTest
@testable import Strand

/// Pins `AICoachEngine.toolCallingActive`'s gating (`CoachTools.swift`), in particular the P9 addition:
/// OpenRouter fronts 300+ models and not every one can take tool definitions, so the tool path there
/// additionally requires the SELECTED model to be in `openRouterToolCapableModels` — populated by
/// `refreshModels()`, empty until a refresh runs. Anthropic (which needs no such per-model check) must
/// stay unaffected by that addition.
@MainActor
final class ToolCallingActiveGatingTests: XCTestCase {

    // `openRouterToolCapableModels` is now persisted in UserDefaults.standard (W2), so a fresh engine
    // restores it. Several tests here assume "fresh engine ⇒ no capabilities known"; clear the key so
    // that premise holds regardless of what a prior test (or a real app run) left behind.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "ai.openRouterToolCapableModels")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ai.openRouterToolCapableModels")
        super.tearDown()
    }

    private func makeEngine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-tool-gating-\(UUID().uuidString)"))
    }

    func testAnthropicNeedsOnlyConsentNotAPerModelCapabilityCheck() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.dataConsent = true
        // No entry in openRouterToolCapableModels at all — must not matter for Anthropic.
        XCTAssertTrue(engine.toolCallingActive)
    }

    func testWithoutDataConsentToolCallingIsNeverActiveRegardlessOfProvider() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.dataConsent = false
        XCTAssertFalse(engine.toolCallingActive)
    }

    func testOpenRouterBeforeAnyRefreshHasNoCapableModelsSoToolsStayOff() {
        let engine = makeEngine()
        engine.provider = .openRouter
        engine.dataConsent = true
        engine.model = "anthropic/claude-sonnet-4.6"
        // openRouterToolCapableModels defaults empty — a fresh connection must use the context path,
        // not guess the curated default model can take tools.
        XCTAssertTrue(engine.openRouterToolCapableModels.isEmpty)
        XCTAssertFalse(engine.toolCallingActive)
    }

    func testOpenRouterActivatesOnlyForAConfirmedCapableModel() {
        let engine = makeEngine()
        engine.provider = .openRouter
        engine.dataConsent = true
        engine.model = "anthropic/claude-sonnet-4.6"
        engine.openRouterToolCapableModels = ["anthropic/claude-sonnet-4.6", "openai/gpt-4o-mini"]
        XCTAssertTrue(engine.toolCallingActive)
    }

    func testOpenRouterStaysOffForAModelKnownNotToSupportTools() {
        let engine = makeEngine()
        engine.provider = .openRouter
        engine.dataConsent = true
        engine.model = "google/gemini-3.1-flash-lite-image"
        engine.openRouterToolCapableModels = ["anthropic/claude-sonnet-4.6"]   // a DIFFERENT model
        XCTAssertFalse(engine.toolCallingActive)
    }

    func testSwitchingOpenRouterModelReevaluatesAgainstTheCapableSet() {
        let engine = makeEngine()
        engine.provider = .openRouter
        engine.dataConsent = true
        engine.openRouterToolCapableModels = ["anthropic/claude-sonnet-4.6"]

        engine.model = "anthropic/claude-sonnet-4.6"
        XCTAssertTrue(engine.toolCallingActive)

        engine.model = "some/other-model"
        XCTAssertFalse(engine.toolCallingActive, "a stale capability set must not cover a model it never named")
    }

    func testGeminiAndCustomNeverGoThroughTheToolPathAtAll() {
        let engine = makeEngine()
        engine.dataConsent = true

        engine.provider = .gemini
        XCTAssertFalse(engine.toolCallingActive, "Gemini deliberately has no ToolCallingClient conformance")

        engine.provider = .custom
        XCTAssertFalse(engine.toolCallingActive, "Custom deliberately has no ToolCallingClient conformance")
    }
}
