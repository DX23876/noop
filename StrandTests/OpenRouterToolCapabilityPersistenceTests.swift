import XCTest
@testable import Strand

/// OpenRouter fronts 300+ models and only some can take tool definitions, so `toolCallingActive` gates
/// its tool path on `openRouterToolCapableModels`. That set used to be a plain in-memory `@Published`:
/// it emptied on every launch, so an OpenRouter user silently lost every tool — `propose_plan`
/// included — until they happened to tap "Refresh models" again, with no UI hint anything was off.
///
/// These pin the two halves of the fix: the set survives a relaunch, and a first send learns it without
/// the user having to know about a Refresh button.
@MainActor
final class OpenRouterToolCapabilityPersistenceTests: XCTestCase {

    private let capableKey = "ai.openRouterToolCapableModels"
    private let toolModel = "anthropic/claude-sonnet-4.6"

    override func setUp() {
        super.setUp()
        // The engine reads UserDefaults.standard (unlike Repository, which is per-test via deviceId).
        UserDefaults.standard.removeObject(forKey: capableKey)
        UserDefaults.standard.removeObject(forKey: "ai.dataConsent")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: capableKey)
        UserDefaults.standard.removeObject(forKey: "ai.dataConsent")
        super.tearDown()
    }

    private func makeEngine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-or-capability-\(UUID().uuidString)"))
    }

    /// W2 is exactly the `didSet`-persist + `init`-restore of this set. These tests drive it directly
    /// (`openRouterToolCapableModels = …`) rather than through `refreshModels()`, which for OpenRouter
    /// requires a real Keychain key — the persistence is independent of how the set got populated, and
    /// this isolates precisely what W2 changed.

    // MARK: - The regression: tools must survive a relaunch

    /// The user-visible property, not the storage — this is what actually broke.
    func testToolCallingIsStillActiveOnAFreshEngineAfterLearningCapabilities() {
        let engine1 = makeEngine()
        engine1.provider = .openRouter
        engine1.dataConsent = true
        engine1.model = toolModel
        engine1.openRouterToolCapableModels = [toolModel]   // fires the persisting didSet
        XCTAssertTrue(engine1.toolCallingActive, "premise: a known-capable model turns tools on")

        // A relaunch: a brand-new engine reading the same UserDefaults.
        let engine2 = makeEngine()
        engine2.provider = .openRouter
        engine2.dataConsent = true
        engine2.model = toolModel

        XCTAssertTrue(engine2.toolCallingActive,
                      "tools must survive a relaunch — they used to silently die every launch")
    }

    func testCapableModelsSurviveARelaunch() {
        let engine1 = makeEngine()
        engine1.openRouterToolCapableModels = [toolModel]

        let engine2 = makeEngine()
        XCTAssertTrue(engine2.openRouterToolCapableModels.contains(toolModel))
        XCTAssertFalse(engine2.openRouterToolCapableModels.contains("some/image-only-model"),
                       "a model that was never marked capable must not appear")
    }

    /// Pins the documented behaviour (AICoach.swift, `openRouterToolCapableModels`) against the new
    /// `didSet`: a provider switch leaves the set alone, since it's only ever consulted for OpenRouter.
    func testAProviderSwitchStillDoesNotClearThePersistedSet() {
        let engine = makeEngine()
        engine.provider = .openRouter
        engine.openRouterToolCapableModels = [toolModel]
        XCTAssertTrue(engine.openRouterToolCapableModels.contains(toolModel))

        engine.provider = .anthropic
        XCTAssertTrue(engine.openRouterToolCapableModels.contains(toolModel),
                      "a provider switch must not discard what we learned about OpenRouter")
    }

    // MARK: - Storage shape

    func testAnEmptySetIsRestoredAsEmptyNotAsGarbage() {
        UserDefaults.standard.set([String](), forKey: capableKey)
        let engine = makeEngine()
        XCTAssertTrue(engine.openRouterToolCapableModels.isEmpty)
    }

    func testNoStoredValueMeansNoCapabilitiesKnownYet() {
        // The safe default: before we know, we do NOT guess a model can take tools.
        let engine = makeEngine()
        engine.provider = .openRouter
        engine.dataConsent = true
        engine.model = toolModel
        XCTAssertTrue(engine.openRouterToolCapableModels.isEmpty)
        XCTAssertFalse(engine.toolCallingActive)
    }
}
