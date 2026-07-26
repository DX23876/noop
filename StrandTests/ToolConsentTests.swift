import XCTest
@testable import Strand

/// Pins per-purpose tool consent (#coach-tool-consent): the migration from the old all-or-nothing
/// `dataConsent`/`includeOnDeviceSignals` bools, the `CoachTool → CoachPurpose` mapping, and the
/// first-session self-heal that lets a brand-new user's default grants apply immediately instead of
/// waiting for a relaunch.
@MainActor
final class ToolConsentTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "ToolConsentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Migration from the legacy bools

    func testNoLegacyConsentMigratesToNothingEnabled() {
        let defaults = freshDefaults()
        XCTAssertTrue(ToolConsent.load(defaults: defaults).enabled.isEmpty)
    }

    /// The four conversational essentials a `dataConsent`-only user actually relied on day to day.
    /// Long history, `stress` and `logs` start OFF even for an existing consenting user — a deliberate narrower default
    /// under the new granular model, not an oversight.
    func testLegacyDataConsentMigratesToTheFourEssentials() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "ai.dataConsent")
        let consent = ToolConsent.load(defaults: defaults)
        XCTAssertEqual(consent.enabled, [.coreBiometrics, .workouts, .planning, .memory])
    }

    /// The second opt-in additionally grants `patterns` (what it always meant) AND `logs` (its own
    /// description already named "Lab Book markers", which `logs` now covers).
    func testLegacyOnDeviceSignalsAdditionallyGrantsPatternsAndLogs() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "ai.dataConsent")
        defaults.set(true, forKey: "ai.includeOnDeviceSignals")
        let consent = ToolConsent.load(defaults: defaults)
        XCTAssertEqual(consent.enabled, [.coreBiometrics, .workouts, .planning, .memory, .patterns, .logs])
    }

    /// The second opt-in alone (without the first, an inconsistent state that shouldn't occur in practice
    /// but must not crash or grant nonsense) still only grants what IT specifically means.
    func testOnDeviceSignalsWithoutDataConsentGrantsOnlyPatternsAndLogs() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "ai.includeOnDeviceSignals")
        let consent = ToolConsent.load(defaults: defaults)
        XCTAssertEqual(consent.enabled, [.patterns, .logs])
    }

    // MARK: - Persistence

    func testAnExplicitlySavedConsentIsReturnedVerbatimIgnoringLegacyKeys() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "ai.dataConsent")   // would otherwise migrate to the four essentials
        var consent = ToolConsent(enabled: [.stress])
        consent.save(defaults: defaults)
        XCTAssertEqual(ToolConsent.load(defaults: defaults).enabled, [.stress],
                       "an explicit save must win over what the legacy bools would migrate to")
    }

    func testHasBeenExplicitlySavedReflectsWhetherSaveWasEverCalled() {
        let defaults = freshDefaults()
        XCTAssertFalse(ToolConsent.hasBeenExplicitlySaved(defaults: defaults))
        ToolConsent(enabled: []).save(defaults: defaults)
        XCTAssertTrue(ToolConsent.hasBeenExplicitlySaved(defaults: defaults))
    }

    // MARK: - CoachTool → CoachPurpose mapping (exhaustive by construction; spot-check every purpose)

    func testEveryToolMapsToExactlyOnePurposeCoveringAllPurposes() {
        let coveredPurposes = Set(CoachTool.allCases.map(\.purpose))
        XCTAssertEqual(coveredPurposes, Set(CoachPurpose.allCases),
                       "every purpose must be reachable by at least one tool, and vice versa")
    }

    func testPatternsPurposeCoversOnlyTheExplicitPatternTools() {
        let patternsTools = CoachTool.allCases.filter { $0.purpose == .patterns }
        XCTAssertEqual(patternsTools, [.personalPatterns, .trainingPreferences])
    }

    func testAllowsReflectsThePurposeMapping() {
        let consent = ToolConsent(enabled: [.workouts])
        XCTAssertTrue(consent.allows(.recentWorkouts))
        XCTAssertFalse(consent.allows(.biometricSummary), "biometricSummary is coreBiometrics, not workouts")
    }

    func testLongHistoryNeedsItsOwnExplicitGrant() {
        let normalConsent = ToolConsent(enabled: [.coreBiometrics])
        XCTAssertFalse(normalConsent.allows(.dataCatalog))
        XCTAssertFalse(normalConsent.allows(.metricHistory))

        let longHistoryConsent = ToolConsent(enabled: [.longHistory])
        XCTAssertTrue(longHistoryConsent.allows(.dataCatalog))
        XCTAssertTrue(longHistoryConsent.allows(.metricHistory))
    }

    func testSimplePrivacyModesKeepSensitiveJournalDataOff() {
        XCTAssertEqual(CoachDataAccessMode.current(for: CoachDataAccessMode.essentials.purposes!), .essentials)
        XCTAssertEqual(CoachDataAccessMode.current(for: CoachDataAccessMode.personal.purposes!), .personal)
        XCTAssertEqual(CoachDataAccessMode.current(for: CoachDataAccessMode.deepInsights.purposes!), .deepInsights)
        XCTAssertFalse(CoachDataAccessMode.deepInsights.purposes!.contains(.sensitiveLogs))
        XCTAssertEqual(CoachDataAccessMode.current(for: [.coreBiometrics]), .expert)
    }

    func testMemoryContextNeedsBothMasterAndMemoryGrants() {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-memory-context-\(UUID().uuidString)"))
        engine.toolConsent = ToolConsent(enabled: [.memory])
        engine.dataConsent = false
        XCTAssertFalse(engine.memoryContextAllowed)

        engine.dataConsent = true
        XCTAssertTrue(engine.memoryContextAllowed)

        engine.toolConsent = ToolConsent(enabled: [.coreBiometrics])
        XCTAssertFalse(engine.memoryContextAllowed)
    }

    func testToolModeContextFiltersMemoryAndPlanBeforeTheProviderSeesThem() {
        let hidden = AICoachEngine.assembledToolModeContext(
            clock: "CLOCK", threadIndex: "PRIVATE THREAD TITLE", plan: "PRIVATE PLAN",
            includeMemory: false, includePlanning: false)
        XCTAssertEqual(hidden, "CLOCK")

        let permitted = AICoachEngine.assembledToolModeContext(
            clock: "CLOCK", threadIndex: "THREAD", plan: "PLAN",
            includeMemory: true, includePlanning: true)
        XCTAssertEqual(permitted, "CLOCK\n\nTHREAD\n\nPLAN")
    }

    func testPerTurnLocalAllowListDefendsTheDispatcherToo() async {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-local-allow-list-\(UUID().uuidString)"))
        engine.dataConsent = true
        engine.toolConsent = ToolConsent(enabled: [.coreBiometrics])

        let result = await engine.runCoachTool("get_biometric_summary", input: [:], allowedTools: [])
        XCTAssertTrue(result.contains("local data policy did not approve"),
                      "a model must not read a tool that was withheld for this specific question")
    }

    // MARK: - First-session self-heal (dataConsent flips true mid-session, not already true at launch)

    private static let dataConsentKey = "ai.dataConsent"
    private static let toolConsentKey = "ai.toolConsent"
    private static let onDeviceSignalsKey = "ai.includeOnDeviceSignals"

    override func tearDown() {
        for key in [Self.dataConsentKey, Self.toolConsentKey, Self.onDeviceSignalsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    /// A brand-new engine (nothing persisted) has empty tool consent. Flipping `dataConsent` on THIS
    /// SESSION — not already true at launch — must grant the default purposes immediately, not leave
    /// `coachTools` empty until the next relaunch re-runs the migration.
    func testFlippingDataConsentOnMidSessionGrantsDefaultsImmediately() {
        for key in [Self.dataConsentKey, Self.toolConsentKey, Self.onDeviceSignalsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let engine = AICoachEngine(repo: Repository(deviceId: "test-toolconsent-\(UUID().uuidString)"))
        XCTAssertTrue(engine.toolConsent.enabled.isEmpty, "nothing persisted yet ⇒ nothing granted")

        engine.dataConsent = true
        XCTAssertEqual(engine.toolConsent.enabled, [.coreBiometrics, .workouts, .planning, .memory],
                       "the migration must apply THIS session, not only on the next relaunch")
    }

    /// Once the user has explicitly configured `toolConsent` (even to something unusual, like nothing at
    /// all), toggling `dataConsent` off and back on must NEVER re-run the migration over that choice.
    func testDataConsentToggleNeverOverwritesAnExplicitToolConsent() {
        for key in [Self.dataConsentKey, Self.toolConsentKey, Self.onDeviceSignalsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let engine = AICoachEngine(repo: Repository(deviceId: "test-toolconsent-\(UUID().uuidString)"))
        engine.dataConsent = true
        engine.toolConsent = ToolConsent(enabled: [.stress])   // an explicit, unusual choice

        engine.dataConsent = false
        engine.dataConsent = true
        XCTAssertEqual(engine.toolConsent.enabled, [.stress],
                       "an explicit choice must survive a dataConsent off/on cycle")
    }
}
