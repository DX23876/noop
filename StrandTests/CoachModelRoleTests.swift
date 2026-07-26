import XCTest
@testable import Strand

/// Pins the P5 model-role architecture: the coach resolves a model PER ROLE (chat / summary /
/// cardAnalysis) through one `model(for:)` point, so the chat conversation can run a strong model while
/// background summary/card work stays on a cheap one — a real cost lever, resolved consistently.
///
/// Keychain-free: these only touch `provider`/`model`/`memoryModel`/`cardModel` (plain @Published
/// state), never `AIKeyStore`.
@MainActor
final class CoachModelRoleTests: XCTestCase {

    private func makeEngine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-model-role-\(UUID().uuidString)"))
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ai.memoryModel")
        UserDefaults.standard.removeObject(forKey: "ai.cardModel")
        UserDefaults.standard.removeObject(forKey: "ai.model")
        super.tearDown()
    }

    // MARK: - 5.6: strong default coaching model, not a mini/flash one

    func testDefaultCoachingModelsAreStrongNotMini() {
        XCTAssertEqual(AIProvider.openAI.defaultModel, "gpt-4o", "the coaching default must not be a mini model")
        XCTAssertEqual(AIProvider.gemini.defaultModel, "gemini-pro-latest", "the coaching default must not be flash")
        XCTAssertEqual(AIProvider.anthropic.defaultModel, "claude-sonnet-4-6")
        // The cheap models stay cheap — that's the whole point of splitting the roles.
        XCTAssertEqual(AIProvider.openAI.cheapModel, "gpt-4o-mini")
        XCTAssertNotEqual(AIProvider.openAI.defaultModel, AIProvider.openAI.cheapModel)
    }

    func testDefaultCoachingModelIsInTheProvidersPickerOptions() {
        // Otherwise the picker would open on a value it can't show as selected.
        for provider in AIProvider.allCases where provider != .custom {
            XCTAssertTrue(provider.modelOptions.contains(provider.defaultModel),
                          "\(provider.rawValue)'s defaultModel isn't in its modelOptions")
        }
    }

    // MARK: - model(for:) resolution

    func testChatRoleUsesTheSelectedModelThenTheDefault() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.model = "claude-opus-4-8"
        XCTAssertEqual(engine.model(for: .chat), "claude-opus-4-8")

        engine.model = "   "   // blank selection falls back to the provider default
        XCTAssertEqual(engine.model(for: .chat), AIProvider.anthropic.defaultModel)
    }

    func testBackgroundRolesDefaultToTheCheapModelWhenNotOverridden() {
        let engine = makeEngine()
        engine.provider = .openAI
        engine.memoryModel = ""
        engine.cardModel = ""
        XCTAssertEqual(engine.model(for: .summary), AIProvider.openAI.cheapModel)
        XCTAssertEqual(engine.model(for: .cardAnalysis), AIProvider.openAI.cheapModel)
    }

    func testBackgroundRolesHonourAnExplicitOverride() {
        let engine = makeEngine()
        engine.provider = .anthropic
        engine.memoryModel = "claude-3-5-haiku-latest"
        engine.cardModel = "claude-haiku-4-5-20251001"
        XCTAssertEqual(engine.model(for: .summary), "claude-3-5-haiku-latest")
        XCTAssertEqual(engine.model(for: .cardAnalysis), "claude-haiku-4-5-20251001")
    }

    /// The stale-provider bug the empty-default fix closes: an unset background role must resolve to the
    /// CURRENT provider's cheap model, not one baked in from whatever provider was selected at launch.
    func testUnsetBackgroundRoleTracksTheCurrentProvider() {
        let engine = makeEngine()
        engine.memoryModel = ""
        engine.provider = .anthropic
        XCTAssertEqual(engine.model(for: .summary), AIProvider.anthropic.cheapModel)
        engine.provider = .openAI
        XCTAssertEqual(engine.model(for: .summary), AIProvider.openAI.cheapModel,
                       "switching provider must move an unset role to the new provider's cheap model")
    }

    /// A background role never resolves to an empty string, even when the provider has no cheap model
    /// (Custom) — it falls through to the chat model.
    func testCustomProviderBackgroundRoleFallsThroughToTheChatModel() {
        let engine = makeEngine()
        engine.provider = .custom
        engine.model = "my-local-model"
        engine.memoryModel = ""
        XCTAssertEqual(engine.model(for: .summary), "my-local-model")
    }
}
