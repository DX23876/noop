import XCTest
import StrandCore
import StrandAnalytics
import StrandTraining
import WhoopStore
import WhoopProtocol

/// #51: a session recorded in Training showed no heart rate and no effort in the lists, although the band
/// had covered all of it. The fill pass read only the `workout` table, and a native session is deliberately
/// never written there, so no fill was ever computed and the overlay had nothing to lay on.
final class RecordedNativeWorkoutFillTests: XCTestCase {

    private func native(id: UUID = UUID(), start: Int, end: Int) -> NativeWorkout {
        NativeWorkout(id: id, title: "Pull", startedAt: start, endedAt: end,
                      plannedDay: StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(start))),
                      routineIds: [], exercises: [], tracker: nil, sessionRPE: 9)
    }

    private func store(start: Int, end: Int) async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        let samples = stride(from: start, through: end, by: 60).map { HRSample(ts: $0, bpm: 120) }
        try await store.insert(Streams(hr: samples), deviceId: "active")
        let day = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(start)))
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: 53, avgHrv: nil, recovery: nil,
                        strain: nil, exerciseCount: nil)], deviceId: "active")
        return store
    }

    func testANativeSessionGetsItsHeartRateAndEffort() async throws {
        let start = 1_794_932_442
        let end = start + 66 * 60
        let store = try await self.store(start: start, end: end)
        try await store.upsertNativeWorkouts([native(start: start, end: end)])
        let reader = StoreReader(store: store, activeDeviceId: "active", registeredWhoopIds: [])

        let outcome = try await WorkoutHeartRateFills.fillRecorded(reader: reader, from: start - 3_600,
                                                                   to: end + 3_600, maxHR: 190, sex: "male")
        XCTAssertEqual(outcome.filled, 1, "the session the band covered must be filled")

        let fills = try await store.workoutHeartRateFills(deviceId: WorkoutHeartRateFills.recordedWorkoutFillNamespace,
                                                          from: start - 60, to: end + 60)
        let fill = fills[WorkoutKey(deviceId: WorkoutHeartRateFills.recordedWorkoutFillNamespace,
                                     startTs: start, sport: "Strength Training")]
        XCTAssertNotNil(fill, "the fill is stored under the key the list reads it back by")
        XCTAssertEqual(fill?.avgHr, 120)
        XCTAssertEqual(fill?.maxHr, 120)
        XCTAssertNotNil(fill?.strain, "with the day's resting rate known the session carries its effort")
        XCTAssertEqual(fill?.restingHrUsed, 53)

        // What the lists actually show: the projected row, after the overlay.
        let shown = await WorkoutHeartRateFills.overlay([NativeTrainingProjection.workoutRow(native(start: start, end: end))],
                                                        store: store)
        XCTAssertEqual(shown.first?.avgHr, 120)
        XCTAssertNotNil(shown.first?.strain)
    }

    func testTheLegacyTwinDoesNotDecideTheFillOfANativeSession() async throws {
        let start = 1_794_932_442
        let end = start + 66 * 60
        let store = try await self.store(start: start, end: end)
        try await store.upsertNativeWorkouts([native(start: start, end: end)])
        // Before the single active session a native workout could carry a manually recorded twin of the
        // same session. Both share the fill key, and the list shows the native row, so its span decides.
        _ = try await store.upsertWorkouts([
            WorkoutRow(startTs: start, endTs: start + 11 * 60, sport: "Strength Training", source: "manual",
                       durationS: 660, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)], deviceId: "active")
        let reader = StoreReader(store: store, activeDeviceId: "active", registeredWhoopIds: [])

        let outcome = try await WorkoutHeartRateFills.fillRecorded(reader: reader, from: start - 3_600,
                                                                   to: end + 3_600, maxHR: 190, sex: "male")
        XCTAssertEqual(outcome.filled, 1, "one key, one fill")
        let fills = try await store.workoutHeartRateFills(deviceId: WorkoutHeartRateFills.recordedWorkoutFillNamespace,
                                                          from: start - 60, to: end + 60)
        let fill = fills[WorkoutKey(deviceId: WorkoutHeartRateFills.recordedWorkoutFillNamespace,
                                     startTs: start, sport: "Strength Training")]
        XCTAssertGreaterThan(fill?.possibleMinutes ?? 0, 60, "the whole session, not the eleven minutes of the twin")
    }

    func testASessionTheBandMissedStaysEmpty() async throws {
        let start = 1_794_932_442
        let end = start + 66 * 60
        let store = try await self.store(start: start, end: end)
        // The session lies a day after the trace: nothing covers it.
        try await store.upsertNativeWorkouts([native(start: start + 86_400, end: end + 86_400)])
        let reader = StoreReader(store: store, activeDeviceId: "active", registeredWhoopIds: [])
        let outcome = try await WorkoutHeartRateFills.fillRecorded(reader: reader, from: start,
                                                                   to: end + 2 * 86_400, maxHR: 190, sex: "male")
        XCTAssertEqual(outcome.filled, 0, "without a trace nothing is claimed")
    }
}
