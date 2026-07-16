import XCTest
@testable import Strand

/// Guards the merge in `refreshModels()` against turning "no model chosen yet" into a selectable
/// entry.
///
/// The Custom provider is the only one whose `defaultModel` is empty — the user is meant to pick from
/// the server's own list. That makes `model == ""` a completely normal state, and exactly the state a
/// user is in the moment they point Custom at a hosted gateway (OpenRouter) and tap Connect. The merge
/// keeps the current model in the list so a hand-typed id isn't lost, but an empty id must not qualify:
/// `connectCustom()` then defaults to `availableModels.first`, would select the empty string, and the
/// request goes out with `"model": ""` — which servers reject with a 400 that reads like a user error
/// but isn't.
@MainActor
final class AICoachEmptyModelMergeTests: XCTestCase {

    /// Custom resolves to an empty (but non-nil) key, so `refreshModels()` gets past its key gate and
    /// reaches the injected fetch without touching the Keychain or the network.
    ///
    /// State is forced rather than assumed: the engine restores provider and model from UserDefaults,
    /// which is process-wide and therefore shared with every other test in the run. Assigning `provider`
    /// alone is not enough — its didSet (which resets the model) only fires when the value actually
    /// changes, so an earlier test that already stored `.custom` would leave its model in place.
    private func makeCustomEngine(deviceId: String) -> AICoachEngine {
        let engine = AICoachEngine(repo: Repository(deviceId: deviceId))
        engine.provider = .custom
        engine.model = ""
        engine.availableModels = []
        return engine
    }

    /// The premise, checked against the provider itself rather than a mutated engine: Custom really does
    /// ship with no model and no options, so `model == ""` is a legitimate state and not a bug upstream.
    func testCustomProviderHasNoDefaultModelOrOptions() {
        XCTAssertEqual(AIProvider.custom.defaultModel, "",
                       "the whole scenario rests on Custom having no default model")
        XCTAssertTrue(AIProvider.custom.modelOptions.isEmpty)
    }

    /// The regression: refreshing while nothing is selected must not seed the list with "".
    func testRefreshWithNoModelSelectedDoesNotInsertAnEmptyEntry() async {
        let engine = makeCustomEngine(deviceId: "test-empty-merge")
        engine.fetchModelsOverride = { _, _ in
            ["openai/gpt-4o", "anthropic/claude-opus-4.1"]
        }

        await engine.refreshModels()

        XCTAssertFalse(engine.availableModels.contains(""),
                       "an empty model id must never become a selectable entry")
        XCTAssertEqual(engine.availableModels.count, 2)
    }

    /// The consequence that actually bit: `connectCustom()` defaults to `availableModels.first`, so a
    /// leading "" would leave the model empty and the request would 400. The first entry must be real.
    func testFirstEntryIsARealModelSoTheConnectDefaultPicksOne() async {
        let engine = makeCustomEngine(deviceId: "test-empty-first")
        engine.fetchModelsOverride = { _, _ in
            ["openai/gpt-4o", "anthropic/claude-opus-4.1"]
        }

        await engine.refreshModels()

        let first = try? XCTUnwrap(engine.availableModels.first)
        XCTAssertNotNil(first)
        XCTAssertFalse((first ?? "").isEmpty,
                       "connectCustom() takes availableModels.first as its default — it must be usable")
    }

    /// Whitespace is empty too: a model of " " is no more sendable than "".
    func testWhitespaceOnlyModelIsNotPreservedEither() async {
        let engine = makeCustomEngine(deviceId: "test-whitespace-merge")
        engine.model = "   "
        engine.fetchModelsOverride = { _, _ in ["openai/gpt-4o"] }

        await engine.refreshModels()

        XCTAssertEqual(engine.availableModels, ["openai/gpt-4o"],
                       "a whitespace-only model must not be carried into the list")
    }

    /// Second line of defence: a model can still end up unset (a failed fetch, a server with an empty
    /// catalogue). Sending then must name the cause instead of forwarding the provider's opaque 400.
    func testSendingWithNoModelAsksTheUserToPickOneInsteadOfCallingTheProvider() async {
        let engine = makeCustomEngine(deviceId: "test-send-no-model")
        XCTAssertEqual(engine.model, "", "precondition: no model selected")

        // No fetch override and no base URL are needed: Custom's resolvedKey is "" (non-nil), so send()
        // clears the key gate and must stop at the model gate — before any network call is built.
        await engine.send("How did I sleep?")

        let error = try? XCTUnwrap(engine.errorText)
        XCTAssertEqual(error, AICoachError.noModel.errorDescription)
        XCTAssertFalse((error ?? "").contains("400"),
                       "the user should be told to pick a model, not shown the server's status code")
    }

    /// The merge's real purpose, which must survive the fix: an id the user typed by hand stays in the
    /// list even when the server's own catalogue doesn't mention it.
    func testHandTypedModelIsStillPreservedWhenTheServerDoesNotListIt() async {
        let engine = makeCustomEngine(deviceId: "test-keep-typed")
        engine.setCustomModel("my-local-llama")
        engine.fetchModelsOverride = { _, _ in ["openai/gpt-4o"] }

        await engine.refreshModels()

        XCTAssertTrue(engine.availableModels.contains("my-local-llama"),
                      "a hand-typed model must not be dropped by a refresh")
        XCTAssertEqual(engine.model, "my-local-llama",
                       "refreshing the list must not change the user's selection")
    }
}
