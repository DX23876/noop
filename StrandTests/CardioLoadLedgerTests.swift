import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins when a stored cardio load answers instead of the heart rate, and that storing a load changes
/// nothing about it.
final class CardioLoadLedgerTests: XCTestCase {
    private func session(id: String = "canonical", start: Int = 1_000, end: Int = 4_600,
                         components: [(String, String)] = [("component", "whoop")]) -> UnifiedTrainingSession {
        let row = WorkoutRow(startTs: start, endTs: end, sport: "Running", source: components.first?.1 ?? "whoop",
                             durationS: Double(end - start), energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                             distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        return UnifiedTrainingSession(
            id: id, kind: .endurance, row: row,
            components: components.map { TrainingSessionComponent(id: $0.0, row: WorkoutRow(
                startTs: start, endTs: end, sport: "Running", source: $0.1, durationS: Double(end - start),
                energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil,
                notes: nil, steps: nil), metadata: nil) },
            fusionOrigin: "automatic")
    }

    private let load = TrainingCardioLoad(sessionId: "canonical", trimp: 132.5, effort: 55.1, source: .noopBand,
                                          coveredMinutes: 58, possibleMinutes: 60)

    /// Storing and reading back gives the very load the heart rate produced — the ledger is a cache of
    /// the same answer, not a second recipe.
    func testAStoredLoadReadsBackIdentically() {
        let fingerprint = Repository.cardioLoadFingerprint(session: session())
        let row = Repository.ledgerRow(for: session(), load: load, fingerprint: fingerprint, maxHR: 188,
                                       computedAt: 1_000_000)
        XCTAssertEqual(Repository.cardioLoad(from: row), load)
        XCTAssertEqual(row.hrmaxUsed, 188)
        XCTAssertEqual(row.method, Repository.cardioLoadMethod)
        XCTAssertEqual(row.methodVersion, Repository.cardiovascularLoadRecipeVersion)
    }

    /// A session its heart rate could not price is stored as that answer, so it is not re-read forever.
    func testAnUnpriceableSessionIsAKnownAnswer() {
        let row = Repository.ledgerRow(for: session(), load: nil,
                                       fingerprint: Repository.cardioLoadFingerprint(session: session()),
                                       maxHR: 188, computedAt: 1_000_000)
        XCTAssertNil(row.trimp)
        XCTAssertEqual(row.hrSource, "none")
        XCTAssertNil(Repository.cardioLoad(from: row))
    }

    /// Heart rate can still arrive for a week after a session (strap offload, watch sync), so a row
    /// computed sooner is provisional and computed again.
    func testARowIsFinalOnlyAWeekAfterTheSessionEnded() {
        let s = session()
        let fingerprint = Repository.cardioLoadFingerprint(session: s)
        let early = Repository.ledgerRow(for: s, load: load, fingerprint: fingerprint, maxHR: 188,
                                         computedAt: 4_600 + Repository.cardioLoadFinalAfterSeconds - 1)
        let late = Repository.ledgerRow(for: s, load: load, fingerprint: fingerprint, maxHR: 188,
                                        computedAt: 4_600 + Repository.cardioLoadFinalAfterSeconds)
        XCTAssertFalse(Repository.ledgerRowIsFinal(early, fingerprint: fingerprint, sessionEnd: 4_600))
        XCTAssertTrue(Repository.ledgerRowIsFinal(late, fingerprint: fingerprint, sessionEnd: 4_600))
        XCTAssertFalse(Repository.ledgerRowIsFinal(late, fingerprint: "another", sessionEnd: 4_600))
    }

    /// The fingerprint follows what makes a different session — its window and its components — and not
    /// the HR maximum, which only an explicit recalculation may apply to history.
    func testTheFingerprintFollowsTheSessionNotTheProfile() {
        let base = Repository.cardioLoadFingerprint(session: session())
        XCTAssertNotEqual(base, Repository.cardioLoadFingerprint(session: session(end: 5_000)))
        XCTAssertNotEqual(base, Repository.cardioLoadFingerprint(
            session: session(components: [("component", "whoop"), ("hk", "apple-health")])))
        XCTAssertEqual(base, Repository.cardioLoadFingerprint(session: session()))
    }

    func testAMissingProfileUsesThePopulationMaximum() {
        XCTAssertEqual(Repository.cardioLoadMaxHR(nil), Double(StrainScorer.defaultMaxHR()))
    }
}
