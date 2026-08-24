import XCTest
import WhoopStore
@testable import Strand

/// Pins the Coach's log, zone, weight and energy contracts: schemas, consent, dispatch and persistence.
@MainActor
final class CoachMyLogsAndZonesTests: XCTestCase {

    private func makeEngine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-mylogs-\(UUID().uuidString)"))
    }

    override func setUp() {
        super.setUp()
        CaffeineLogStore.shared.clearAll()
    }

    override func tearDown() {
        CaffeineLogStore.shared.clearAll()
        super.tearDown()
    }

    // MARK: - get_my_logs contract edges

    /// An unknown kind returns recoverable guidance text — never throws, never an empty string (a blank
    /// tool result is what makes a model hallucinate).
    func testUnknownKindReturnsRecoverableText() async {
        let result = await makeEngine().myLogsTool(kind: "sleep", days: 14)
        XCTAssertTrue(result.contains("Unknown log kind"))
        XCTAssertTrue(result.contains("caffeine, journal, lab, hydration, mood"))
    }

    /// `lab` refuses without the `.logs` purpose granted (#coach-tool-consent), and short-circuits BEFORE
    /// any store read.
    func testLabRefusesWithoutLogsConsent() async {
        let engine = makeEngine()
        engine.toolConsent = ToolConsent(enabled: [])
        let result = await engine.myLogsTool(kind: "lab", days: 14)
        XCTAssertTrue(result.contains("hasn't shared their Lab Book"))
    }

    /// An empty caffeine log reads back as words, not an empty string.
    func testEmptyCaffeineLogReadsAsWords() async {
        let result = await makeEngine().myLogsTool(kind: "caffeine", days: 14)
        XCTAssertEqual(result, "No caffeine logged in the last 14 days.")
    }

    /// A logged intake is read back with its amount and an "still active" line — the read half of the
    /// write the coach already had (`log_caffeine` → `CaffeineLogStore.shared`).
    func testLoggedCaffeineIsReadBack() async {
        CaffeineLogStore.shared.log(at: Date(), mg: 95)
        let result = await makeEngine().myLogsTool(kind: "caffeine", days: 14)
        XCTAssertTrue(result.contains("CAFFEINE LOG"))
        XCTAssertTrue(result.contains("95 mg"))
        XCTAssertTrue(result.contains("Still active now"))
    }

    // MARK: - Tool census (the guard that outlives this plan)

    /// The core long-history tools are on the wire, and the full-purpose (except patterns) census is pinned
    /// so any future addition is a deliberately reviewed cost bump rather than drift.
    func testToolCensusIncludesLongHistoryToolsAndIsPinned() {
        let engine = makeEngine()
        engine.toolConsent = ToolConsent(enabled: Set(CoachPurpose.allCases.filter { $0 != .patterns }))
        XCTAssertTrue(engine.coachTools.contains(.myLogs))
        XCTAssertTrue(engine.coachTools.contains(.zoneMinutes))
        XCTAssertTrue(engine.coachTools.contains(.dataCatalog))
        XCTAssertTrue(engine.coachTools.contains(.metricHistory))
        XCTAssertTrue(engine.coachTools.contains(.logWeight))
        XCTAssertTrue(engine.coachTools.contains(.energyBalance))
        // 25 → 26: `estimate_session_effort` joined the wire. Reviewed and intended — the coach was
        // stating Effort figures its own arithmetic could not produce ("15 for a 20-minute Zone 2
        // ride"), and one small tool definition is a fair price for prescriptions that hold up.
        XCTAssertEqual(engine.coachTools.count, 28,
                       "tool count changed — confirm the added per-round cost is intended")

        engine.toolConsent.enabled.insert(.patterns)
        XCTAssertEqual(engine.coachTools.count, 30,
                       "the second opt-in adds personal patterns and training preferences")
    }

    /// Every tool has a non-empty description and a well-formed object input schema — the new ones
    /// included — so none reaches a provider as a nameless or malformed definition.
    func testEveryToolHasADescriptionAndObjectSchema() {
        for tool in CoachTool.allCases {
            XCTAssertFalse(tool.description.isEmpty, "\(tool.rawValue) has no description")
            XCTAssertEqual(tool.inputSchema["type"] as? String, "object",
                           "\(tool.rawValue) schema is not an object")
        }
    }

    // MARK: - Weight and energy contracts

    func testLogWeightRejectsMissingAndImplausibleValues() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "test-weight-invalid")
        repo.setStoreForTesting(store)
        let engine = AICoachEngine(repo: repo)

        let missing = await engine.logWeightTool(kg: nil, day: nil)
        let implausible = await engine.logWeightTool(kg: 1, day: nil)
        XCTAssertTrue(missing.contains("nothing was logged"))
        XCTAssertTrue(implausible.contains("nothing was logged"))
        let rows = try await store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId)
        XCTAssertTrue(rows.isEmpty)
    }

    func testLogWeightPersistsOnRequestedDayAndFeedsCanonicalSeries() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "test-weight-valid")
        repo.setStoreForTesting(store)
        let engine = AICoachEngine(repo: repo)
        engine.dataConsent = true
        engine.toolConsent = ToolConsent(enabled: [.logs])
        let requestedDay = Repository.logicalDayKey(Date())

        let result = await engine.runCoachTool(CoachTool.logWeight.rawValue,
                                               input: ["weight_kg": 82.4, "day": requestedDay])
        XCTAssertTrue(result.contains("Logged 82.4 kg for \(requestedDay)"))

        let rows = try await store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.day, requestedDay)
        XCTAssertEqual(rows.first?.weightKg, 82.4)
        let canonical = await repo.weightSeries(days: 30)
        XCTAssertEqual(canonical.last?.day, requestedDay)
        XCTAssertEqual(canonical.last?.source, .manual)
    }

    func testCoachSourceLabelNamesNoopWeighIns() {
        XCTAssertEqual(CoachLocalSourceLabel.label(WhoopStore.noopWeightSourceId),
                       "Weigh-ins logged in NOOP")
    }

    func testEnergyAnswerAlwaysNamesSourceCoverageEstimateAndNoFoodInference() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "test-energy-answer")
        repo.setStoreForTesting(store)
        let engine = AICoachEngine(repo: repo)
        engine.dataConsent = true
        engine.toolConsent = ToolConsent(enabled: [.coreBiometrics])
        let result = await engine.runCoachTool(CoachTool.energyBalance.rawValue, input: [:])

        XCTAssertTrue(result.contains("SOURCE:"))
        XCTAssertTrue(result.contains("ENERGY_COVERAGE:"))
        XCTAssertTrue(result.contains("CONFIDENCE:"))
        XCTAssertTrue(result.localizedCaseInsensitiveContains("modelled"))
        XCTAssertTrue(result.contains("Do not infer what the user should eat"))
    }

    func testNewToolsUseExpectedConsentPurposes() {
        XCTAssertEqual(CoachTool.logWeight.purpose, .logs)
        XCTAssertEqual(CoachTool.energyBalance.purpose, .coreBiometrics)
    }
}
