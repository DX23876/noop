import XCTest
import StrandAnalytics
import StrandCore
import WhoopProtocol
import WhoopStore

/// A workout whose heart rate is filled from the band is scored against its day's Effort resting heart rate
/// (`EffortRestingHR`), the one the day around it is scored against, not the lower one the day shows
/// (`StoreReader.fillRestingHRByDay`, 2026-11-25).
final class EffortRestingHRFillTests: XCTestCase {

    private func morning(daysAgo: Int) -> Int {
        let day = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(daysAgo) * 86_400))
        return Int(day.timeIntervalSince1970) + 8 * 3600
    }

    private func daily(_ day: String, restingHr: Int) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: restingHr, avgHrv: nil, recovery: nil, strain: nil,
                    exerciseCount: nil)
    }

    func testAFillTakesTheDaysEffortRestingRateAndADayWithoutOneItsOwn() async throws {
        let store = try await WhoopStore.inMemory()
        let scored = morning(daysAgo: 3), unscored = morning(daysAgo: 2)
        let scoredDay = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(scored)))
        let unscoredDay = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(unscored)))
        let trace = { (start: Int) in stride(from: start, through: start + 40 * 60, by: 60).map { HRSample(ts: $0, bpm: 120) } }
        try await store.insert(Streams(hr: trace(scored) + trace(unscored)), deviceId: "active")
        _ = try await store.upsertDailyMetrics([daily(scoredDay, restingHr: 53), daily(unscoredDay, restingHr: 55)],
                                               deviceId: "active")
        _ = try await store.upsertMetricSeries([MetricPoint(day: scoredDay, key: EffortRestingHR.seriesKey, value: 60)],
                                               deviceId: "active-noop")
        let walk = { (start: Int) in
            WorkoutRow(startTs: start, endTs: start + 40 * 60, sport: "Walking", source: "manual", durationS: 2_400,
                       energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil,
                       notes: nil, steps: nil)
        }
        _ = try await store.upsertWorkouts([walk(scored), walk(unscored)], deviceId: "active")
        let reader = StoreReader(store: store, activeDeviceId: "active", registeredWhoopIds: [])

        let outcome = try await WorkoutHeartRateFills.fillRecorded(reader: reader, from: scored - 3_600,
                                                                   to: unscored + 3_600, maxHR: 190, sex: "male")
        XCTAssertEqual(outcome.filled, 2)
        let fills = try await store.workoutHeartRateFills(deviceId: WorkoutHeartRateFills.recordedWorkoutFillNamespace,
                                                          from: scored - 60, to: unscored + 60)
        func fill(_ start: Int) -> WorkoutHeartRateFillRow? {
            fills[WorkoutKey(deviceId: WorkoutHeartRateFills.recordedWorkoutFillNamespace, startTs: start,
                             sport: "Walking")]
        }
        XCTAssertEqual(fill(scored)?.restingHrUsed, 60, "the day the pass scored lends its Effort resting rate")
        XCTAssertEqual(try XCTUnwrap(fill(scored)?.strain), try XCTUnwrap(StrainScorer.strain(
            trace(scored), maxHR: 190, restingHR: 60, lowIntensity: .counted)), accuracy: 1e-9)
        XCTAssertEqual(fill(unscored)?.restingHrUsed, 55, "a day the pass has not scored keeps its own")
    }
}
