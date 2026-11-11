import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// A Health Connect session gets its Effort from the minute heart rate the import filed beside it, as an Apple Health
/// workout does from the Watch's minutes (`WorkoutHeartRateFills.fillHealthConnect`).
final class HealthConnectWorkoutFillTests: XCTestCase {
    func testAHealthConnectRunGetsItsEffortFromItsMinutes() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let start = Int(Date().timeIntervalSince1970) - 3 * 86_400
        let run = WorkoutRow(startTs: start, endTs: start + 40 * 60, sport: "Running", source: "health-connect",
                             durationS: 2400, energyKcal: nil, avgHr: 140, maxHr: 159, strain: nil, distanceM: nil,
                             zonesJSON: nil, notes: "Morning Run", steps: nil)
        _ = try await store.upsertWorkouts([run], deviceId: WorkoutSource.healthConnectSource)
        // The import files Health Connect's resting heart rate in the daily rows of days the strap does not cover.
        let day = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(start)))
        _ = try await store.upsertDailyMetrics([DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                                                            lightMin: nil, disturbances: nil, restingHr: 55, avgHrv: nil,
                                                            recovery: nil, strain: nil, exerciseCount: 1, steps: nil)],
                                               deviceId: "my-whoop")
        try await WorkoutHeartRateFills.fileHealthConnectMinutes(store: store, startTs: start, sport: "Running",
                                                                samples: (0..<40).map { (ts: start + $0 * 60, bpm: 130 + Double($0)) })
        let outcome = try await WorkoutHeartRateFills.fillHealthConnect(reader: reader, from: start - 60, to: start + 60, maxHR: 190)
        XCTAssertEqual(outcome.filled, 1)
        let rows = try await store.workouts(deviceId: WorkoutSource.healthConnectSource, from: start - 60, to: start + 60,
                                            limit: 10, offset: 0)
        let shown = await WorkoutHeartRateFills.overlay(rows, store: store)
        XCTAssertNotNil(shown.first?.strain)
        XCTAssertEqual(shown.first?.avgHr, 140, "the import's own average stays")
    }
}
