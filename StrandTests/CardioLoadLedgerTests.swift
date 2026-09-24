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
                                       restingHR: 55, computedAt: 1_000_000)
        XCTAssertEqual(Repository.cardioLoad(from: row), load)
        XCTAssertEqual(row.hrmaxUsed, 188)
        XCTAssertEqual(row.restingHrUsed, 55, "the resting rate a load was priced with is kept with it")
        XCTAssertEqual(row.method, "banister-hrr")
        XCTAssertEqual(row.methodVersion, Repository.cardiovascularLoadRecipeVersion)
    }

    /// A session its heart rate could not price is stored as that answer, so it is not re-read forever.
    func testAnUnpriceableSessionIsAKnownAnswer() {
        let row = Repository.ledgerRow(for: session(), load: nil,
                                       fingerprint: Repository.cardioLoadFingerprint(session: session()),
                                       maxHR: 188, restingHR: 55, computedAt: 1_000_000)
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
                                         restingHR: 55, computedAt: 4_600 + Repository.cardioLoadFinalAfterSeconds - 1)
        let late = Repository.ledgerRow(for: s, load: load, fingerprint: fingerprint, maxHR: 188,
                                        restingHR: 55, computedAt: 4_600 + Repository.cardioLoadFinalAfterSeconds)
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

    // MARK: - Banister inputs (P4)

    /// The resting rate is the median of the week around the session — the body that did it — and widens
    /// only when that week has no reading at all.
    func testRestingRateIsTheMedianOfTheWeekAroundTheSession() {
        let week = ["2026-03-07": 50.0, "2026-03-09": 54, "2026-03-10": 70, "2026-03-13": 52,
                    "2026-04-20": 90]
        XCTAssertEqual(Repository.cardioLoadRestingHR(day: "2026-03-10", restingByDay: week), 53,
                       "median of 50, 54, 70, 52 — the April reading is outside the week")
        XCTAssertEqual(Repository.cardioLoadRestingHR(day: "2026-03-25", restingByDay: week), 54,
                       "no reading within three days: the month around it, April included")
        XCTAssertEqual(Repository.cardioLoadRestingHR(day: "2025-01-01", restingByDay: week), 54,
                       "nothing within a month: every day read")
        XCTAssertEqual(Repository.cardioLoadRestingHR(day: "2026-03-10", restingByDay: [:]),
                       StrainScorer.defaultRestingHR)
    }

    private func sessionWithAverage(_ bpm: Int?) -> UnifiedTrainingSession {
        let base = session()
        let row = WorkoutRow(startTs: base.row.startTs, endTs: base.row.endTs, sport: "Running", source: "apple-health",
                             durationS: 3_600, energyKcal: nil, avgHr: bpm, maxHr: nil, strain: nil,
                             distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        return UnifiedTrainingSession(id: base.id, kind: .endurance, row: row, components: base.components,
                                      fusionOrigin: "automatic")
    }

    /// A session without a trace is estimated from its average heart rate — Banister's original form —
    /// and filed apart from measured loads, so no comparison can read it.
    func testAnAverageHeartRateEstimateIsFiledApart() throws {
        let estimate = try XCTUnwrap(Repository.averageHeartRateLoad(for: sessionWithAverage(125), maxHR: 190,
                                                                      restingHR: 60, sex: "male"))
        XCTAssertEqual(estimate.source, .averageHeartRate)
        XCTAssertEqual(estimate.trimp, 50.1446, accuracy: 0.001)
        XCTAssertNil(Repository.averageHeartRateLoad(for: sessionWithAverage(nil), maxHR: 190, restingHR: 60,
                                                     sex: "male"))

        var resolution = TrainingCardioLoadResolution()
        resolution.record(estimate)
        resolution.record(load)
        XCTAssertEqual(resolution.loads.keys.sorted(), ["canonical"])
        XCTAssertEqual(resolution.loads["canonical"]?.source, .noopBand)
        XCTAssertEqual(resolution.estimates["canonical"]?.source, .averageHeartRate)

        let row = Repository.ledgerRow(for: session(), load: estimate,
                                       fingerprint: Repository.cardioLoadFingerprint(session: session()),
                                       maxHR: 190, restingHR: 60, computedAt: 1_000_000)
        XCTAssertEqual(row.hrSource, "avg_hr")
        XCTAssertEqual(Repository.cardioLoad(from: row)?.source, .averageHeartRate)
    }

    /// The lane's daily series reads measured loads only: a day whose one session is an estimate is a
    /// day the data could not measure, never rest and never a figure.
    func testTheLaneNeverReadsAnEstimate() throws {
        let estimate = try XCTUnwrap(Repository.averageHeartRateLoad(for: sessionWithAverage(125), maxHR: 190,
                                                                      restingHR: 60, sex: "male"))
        var resolution = TrainingCardioLoadResolution()
        resolution.record(estimate)
        let series = TrainingLoadLanes.cardioSeries(sessions: [sessionWithAverage(125)], resolution: resolution,
                                                    tzOffsetSeconds: 0)
        XCTAssertTrue(series.byDay.isEmpty)
        XCTAssertEqual(series.unknownDays.count, 1)
    }

    func testAMissingProfileUsesThePopulationMaximum() {
        XCTAssertEqual(Repository.cardioLoadMaxHR(nil), Double(StrainScorer.defaultMaxHR()))
    }
}
