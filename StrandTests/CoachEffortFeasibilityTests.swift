import XCTest
@testable import Strand
import StrandAnalytics

/// The reported defect end-to-end: the coach offered "a 15-effort, 20-minute Zone 2 cycle", a target
/// its own Effort arithmetic cannot produce. `propose_plan` took `target_effort` as a free number, so
/// the impossible figure went straight onto the Today card.
///
/// The pure maths is pinned in `EffortFeasibilityTests`; this covers the app-target wiring, which no
/// default CI compiles (`app-build.yml` is off).
@MainActor
final class CoachEffortFeasibilityTests: XCTestCase {

    private func makeEngine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: "test-effort-\(UUID().uuidString)"))
    }

    override func setUp() {
        super.setUp()
        CoachPlanStore.shared.clearAll()
    }

    override func tearDown() {
        CoachPlanStore.shared.clearAll()
        super.tearDown()
    }

    private var today: String { Repository.localDayKey(Date()) }

    /// THE case. An impossible target is replaced, the reply says so in terms the model can act on,
    /// and what gets STORED is the reachable figure — the Today card can no longer show 15.
    func testImpossibleTargetIsReplacedAndTheReplyExplains() async throws {
        let engine = makeEngine()
        let reply = await engine.proposePlanTool(
            day: today, sport: "Zone 2 ride", intent: "easy",
            targetEffort: 15, rationale: "rest day spin", time: nil,
            zone: 2, durationMin: 20)

        XCTAssertTrue(reply.contains("replaced"), reply)
        XCTAssertTrue(reply.contains("Zone 2"), reply)

        let stored = try XCTUnwrap(CoachPlanStore.shared.proposals(forDay: today).first)
        let effort = try XCTUnwrap(stored.targetEffort)
        XCTAssertGreaterThan(effort, 20, "stored target was \(effort); 15 must not survive")
        XCTAssertEqual(stored.zone, 2)
        XCTAssertEqual(stored.durationMin, 20)
    }

    /// A figure close to what the session is worth is the coach's judgement about where in the band to
    /// sit, and must survive untouched — the check exists to catch impossibilities, not to flatten every
    /// plan onto one number.
    func testAPlausibleTargetIsKept() async throws {
        let engine = makeEngine()
        let zoneSet = ProfileStore().hrZoneSet
        let resting = await engine.recentRestingHR()
        let range = try XCTUnwrap(EffortFeasibility.sessionEffortRange(
            zone: 3, minutes: 40, zoneSet: zoneSet, restingHR: resting))
        let nudged = range.typical - 2

        let reply = await engine.proposePlanTool(
            day: today, sport: "Tempo run", intent: "moderate",
            targetEffort: nudged, rationale: "steady", time: nil,
            zone: 3, durationMin: 40)

        XCTAssertFalse(reply.contains("replaced"), reply)
        let stored = try XCTUnwrap(CoachPlanStore.shared.proposals(forDay: today).first)
        XCTAssertEqual(try XCTUnwrap(stored.targetEffort), nudged, accuracy: 1e-6)
    }

    /// With no target supplied, the app fills one in rather than leaving the card blank.
    func testMissingTargetIsComputed() async throws {
        let engine = makeEngine()
        _ = await engine.proposePlanTool(
            day: today, sport: "Zone 2 ride", intent: "easy",
            targetEffort: nil, rationale: "aerobic base", time: nil,
            zone: 2, durationMin: 45)

        let stored = try XCTUnwrap(CoachPlanStore.shared.proposals(forDay: today).first)
        XCTAssertNotNil(stored.targetEffort)
        XCTAssertGreaterThan(try XCTUnwrap(stored.targetEffort), 0)
    }

    /// Without zone AND duration there is nothing to check against, so behaviour is exactly as before —
    /// no regression for a provider or a session that doesn't carry them (rest days, mobility).
    func testWithoutZoneAndDurationTheTargetIsUntouched() async throws {
        let engine = makeEngine()
        let reply = await engine.proposePlanTool(
            day: today, sport: "Mobility", intent: "mobility",
            targetEffort: 12, rationale: "hips", time: nil,
            zone: nil, durationMin: nil)

        XCTAssertFalse(reply.contains("replaced"), reply)
        let stored = try XCTUnwrap(CoachPlanStore.shared.proposals(forDay: today).first)
        XCTAssertEqual(try XCTUnwrap(stored.targetEffort), 12, accuracy: 1e-9)
        XCTAssertNil(stored.zone)
        XCTAssertNil(stored.durationMin)
    }

    /// Out-of-range zone/duration are ignored rather than trusted — a model can send anything.
    func testNonsenseZoneOrDurationIsDroppedNotStored() async throws {
        let engine = makeEngine()
        _ = await engine.proposePlanTool(
            day: today, sport: "Ride", intent: "easy",
            targetEffort: 20, rationale: "x", time: nil,
            zone: 9, durationMin: -5)

        let stored = try XCTUnwrap(CoachPlanStore.shared.proposals(forDay: today).first)
        XCTAssertNil(stored.zone)
        XCTAssertNil(stored.durationMin)
        XCTAssertEqual(try XCTUnwrap(stored.targetEffort), 20, accuracy: 1e-9)
    }

    /// Both summaries must carry the session's SHAPE, so a wearer sees what they agreed to rather than a
    /// bare sport name — and so the coach's context describes the same session the card does.
    ///
    /// The two differ in exactly one place: the Effort figure. The user's string renders the wearer's
    /// display axis, the model's stays on the canonical 0–100 the tool schema accepts (see
    /// `PlanProposalEffortScaleTests`). This test used to read one shared string; the split is why it now
    /// checks both.
    func testSummaryNamesDurationAndZone() {
        let p = PlanProposal(day: today, sport: "Zone 2 ride", intent: .easy,
                             targetEffort: 34, zone: 2, durationMin: 20)
        for summary in [p.summary(effortScale: .hundred), p.contextSummary()] {
            XCTAssertTrue(summary.contains("20 min"), summary)
            XCTAssertTrue(summary.contains("Zone 2"), summary)
            XCTAssertTrue(summary.contains("34"), summary)
        }
    }

    /// A plan stored before this change decodes with no zone/duration rather than failing to load.
    func testOlderStoredProposalsStillDecode() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","day":"\(today)","sport":"Ride","intent":"easy",
         "targetEffort":15,"rationale":"old","status":"proposed","source":"coachProposed",
         "goalIds":[],"createdAt":0,"rejectedWorkoutKeys":[]}
        """
        let decoded = try JSONDecoder().decode(PlanProposal.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.zone)
        XCTAssertNil(decoded.durationMin)
        XCTAssertEqual(try XCTUnwrap(decoded.targetEffort), 15, accuracy: 1e-9)
    }

    // MARK: - estimate_session_effort

    func testEstimateToolReportsBandsAndAFigure() async {
        let out = await makeEngine().estimateSessionEffortTool(zone: 2, durationMin: 20)
        XCTAssertTrue(out.contains("HR ZONES"), out)
        XCTAssertTrue(out.contains("Zone 2"), out)
        XCTAssertTrue(out.contains("Effort"), out)
    }

    func testEstimateToolAsksForWhatItNeeds() async {
        let engine = makeEngine()
        let noZone = await engine.estimateSessionEffortTool(zone: nil, durationMin: 20)
        XCTAssertTrue(noZone.contains("1 to 5"), noZone)
        let noDuration = await engine.estimateSessionEffortTool(zone: 2, durationMin: nil)
        XCTAssertTrue(noDuration.contains("minutes"), noDuration)
    }
}
