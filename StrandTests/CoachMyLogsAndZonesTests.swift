import XCTest
@testable import Strand

/// Pins T5 of Etappe T: the two new tools. `get_my_logs` closes the write-without-read asymmetry (the
/// coach could log a coffee but not recall it) with ONE tool across five kinds; `get_zone_minutes`
/// closes the propose_plan Zone-2 loop. These cover the store-free contract edges — recoverable text on
/// an unknown kind, the `lab` consent gate, an empty caffeine log, and the tool census — since the
/// codebase has no headless store-seeding seam for the data-bearing paths.
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
        XCTAssertEqual(engine.coachTools.count, 25,
                       "tool count changed — confirm the added per-round cost is intended")

        engine.toolConsent.enabled.insert(.patterns)
        XCTAssertEqual(engine.coachTools.count, 27,
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
}
