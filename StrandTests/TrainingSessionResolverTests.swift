import XCTest
import WhoopStore
@testable import Strand

final class TrainingSessionResolverTests: XCTestCase {
    private func row(_ start: Int, _ end: Int, sport: String, source: String,
                     distance: Double? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: nil, avgHr: nil, maxHr: nil,
                   strain: nil, distanceM: distance, zonesJSON: nil, notes: nil, steps: nil)
    }

    func testHighConfidenceHealthAndHevyTwinsFuseAndKeepComplementaryFields() {
        let hevy = row(1_000, 4_600, sport: "Strength Training", source: "hevy")
        let health = row(1_030, 4_570, sport: "Strength Training", source: "apple-health", distance: 500)
        let result = TrainingSessionResolver.resolve(rows: [hevy, health], metadata: [], links: [], preferences: [])
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].components.count, 2)
        XCTAssertEqual(result.sessions[0].kind, .strength)
        XCTAssertEqual(result.sessions[0].row.source, "hevy")
        XCTAssertEqual(result.sessions[0].row.distanceM, 500)
        XCTAssertEqual(result.generatedLinks.count, 2)
    }

    func testAmbiguousCandidatesAreNotAutomaticallyMerged() {
        let health = row(1_000, 4_600, sport: "Running", source: "apple-health")
        let first = row(1_100, 4_500, sport: "Running", source: "whoop")
        let second = row(1_200, 4_400, sport: "Running", source: "manual")
        let result = TrainingSessionResolver.resolve(rows: [health, first, second], metadata: [], links: [], preferences: [])
        XCTAssertEqual(result.sessions.count, 3)
        XCTAssertFalse(result.ambiguous.isEmpty)
    }

    /// The early Apple Health rows were stored as `apple_health`. A component read back under that
    /// spelling has to fuse exactly like a current one, or every workout imported back then would be
    /// offered as a duplicate of itself forever.
    func testTheLegacyAppleHealthSpellingFusesLikeTheCurrentOne() {
        let hevy = row(1_000, 4_600, sport: "Strength Training", source: "hevy")
        let legacy = row(1_030, 4_570, sport: "Strength Training", source: "apple_health")
        let result = TrainingSessionResolver.resolve(rows: [hevy, legacy], metadata: [], links: [],
                                                     preferences: [])
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].components.count, 2)
    }

    /// Two sessions can overlap heavily and still be two sessions — a treadmill hour started twelve
    /// minutes after a strap bout is not the same bout. The pairing sweep stops at ten minutes, and
    /// this pins that boundary rather than the sweep's implementation.
    func testSessionsStartedMoreThanTenMinutesApartAreNeverPaired() {
        let health = row(1_000, 5_000, sport: "Running", source: "apple-health")
        let strap = row(1_700, 5_600, sport: "Running", source: "whoop")
        let result = TrainingSessionResolver.resolve(rows: [health, strap], metadata: [], links: [],
                                                     preferences: [])
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertTrue(result.ambiguous.isEmpty)
    }

    /// An ambiguous group is offered ONCE, with every candidate in it. Reported per member, the wearer
    /// would be asked the same question three times and could answer it inconsistently.
    func testAnAmbiguousGroupIsReportedOnceAndNamesEveryCandidate() {
        let health = row(1_000, 4_600, sport: "Running", source: "apple-health")
        let strap = row(1_100, 4_500, sport: "Running", source: "whoop")
        let manual = row(1_200, 4_400, sport: "Running", source: "manual")
        let result = TrainingSessionResolver.resolve(rows: [health, strap, manual], metadata: [],
                                                     links: [], preferences: [])
        XCTAssertEqual(result.sessions.count, 3)
        XCTAssertEqual(result.ambiguous.count, 1)
        XCTAssertEqual(Set(result.ambiguous[0].map(\.id)).count, 3)
    }

    /// A session that already has an id keeps it when another component joins, and the new component is
    /// linked to that id. A renamed session would orphan the wearer's session-RPE, which names it.
    func testAnExistingSessionIdIsReusedRatherThanRenamed() {
        let hevy = row(1_000, 4_600, sport: "Strength Training", source: "hevy")
        let health = row(1_030, 4_570, sport: "Strength Training", source: "apple-health")
        let link = TrainingSessionLinkRow(componentKey: "apple-health|1030|strengthtraining",
                                          sessionId: "session|chosen-earlier", origin: "user",
                                          updatedAtTs: 1)
        let result = TrainingSessionResolver.resolve(rows: [hevy, health], metadata: [], links: [link],
                                                     preferences: [])
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].id, "session|chosen-earlier")
        XCTAssertEqual(result.generatedLinks.map(\.componentKey), ["hevy|1000|strengthtraining"])
        XCTAssertEqual(result.generatedLinks.first?.sessionId, "session|chosen-earlier")
    }

    /// The backfill is idempotent: fed its own links, a second pass writes nothing and reaches the same
    /// sessions. Opening a longer history therefore enriches old sessions without rewriting them.
    func testRunningAgainWithItsOwnLinksWritesNothingNew() {
        let rows = [row(1_000, 4_600, sport: "Strength Training", source: "hevy"),
                    row(1_030, 4_570, sport: "Strength Training", source: "apple-health")]
        let first = TrainingSessionResolver.resolve(rows: rows, metadata: [], links: [], preferences: [])
        let second = TrainingSessionResolver.resolve(rows: rows, metadata: [],
                                                     links: first.generatedLinks, preferences: [])
        XCTAssertEqual(second.sessions.map(\.id), first.sessions.map(\.id))
        XCTAssertTrue(second.generatedLinks.isEmpty)
    }

    func testExplicitSeparateDecisionPreventsAutomaticFusion() {
        let a = row(1_000, 4_600, sport: "Running", source: "apple-health")
        let b = row(1_030, 4_570, sport: "Running", source: "whoop")
        let decision = TrainingSessionPairDecisionRow(leftKey: "apple-health|1000|running",
            rightKey: "whoop|1030|running", decision: "separate", updatedAtTs: 1)
        let result = TrainingSessionResolver.resolve(rows: [a, b], metadata: [], links: [],
                                                     decisions: [decision], preferences: [])
        XCTAssertEqual(result.sessions.count, 2)
    }
}
