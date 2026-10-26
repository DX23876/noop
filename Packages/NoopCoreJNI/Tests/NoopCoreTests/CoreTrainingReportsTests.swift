import XCTest
import NoopCore
import StrandAnalytics
import StrandCore
import WhoopStore

final class CoreTrainingReportsTests: XCTestCase {
    func testCardioKeepsMeasuredPaceSeparateFromUnmeasuredHeartRateLoad() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "strap-a", registeredWhoopIds: [])
        let now = Int(try XCTUnwrap(Calendar.current.date(from:
            DateComponents(year: 2026, month: 10, day: 26, hour: 12))).timeIntervalSince1970)
        let rows = [0, 7, 14, 21].map { back -> WorkoutRow in
            let start = now - back * 86_400 - 7_200
            return WorkoutRow(startTs: start, endTs: start + 1_800, sport: "Running", source: "manual",
                durationS: 1_800, energyKcal: 300, avgHr: 140, maxHr: 165, strain: nil,
                distanceM: 5_000, zonesJSON: nil, notes: nil, steps: 5_500)
        }
        _ = try await store.upsertWorkouts(rows, deviceId: "strap-a")
        let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
        let daily = (0..<50).map { back in
            DailyMetric(day: WeeklyDigestEngine.addDays(today, -back), totalSleepMin: nil, efficiency: nil,
                deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                restingHr: 50, avgHrv: 70, recovery: 80, strain: 6, exerciseCount: 0, respRateBpm: 15)
        }
        _ = try await store.upsertDailyMetrics(daily, deviceId: "strap-a-noop")
        let report = await CoreTrainingReports.cardio(reader: reader, maxHR: 190, sex: "male",
            weekOffset: 5, sport: "missing", zoneSet: HRZones.zones(maxHR: 190), now: now)

        XCTAssertEqual(report.selection.weekOffset, 0)
        XCTAssertEqual(report.selection.minWeekOffset, -3)
        XCTAssertEqual(report.weekSessions, 1)
        XCTAssertEqual(report.minutes, 30)
        XCTAssertEqual(report.distanceM, 5_000)
        XCTAssertEqual(report.charge, 80, "locally computed days contribute just like imported days")
        XCTAssertEqual(report.progress.selectedSport, "Running")
        XCTAssertEqual(report.sessions.count, 4)
        XCTAssertEqual(report.sessions.first?.paceSecPerKm, 360)
        XCTAssertEqual(report.sessions.first?.beatsPerKm, 840)
        XCTAssertEqual(report.lane?.sevenDayTotal, 0, "an average-HR estimate must not become measured lane load")
        XCTAssertNil(report.zones, "zone time cannot be reconstructed from average heart rate")
        XCTAssertEqual(report.progress.paceBests.count, 1)
        XCTAssertNotEqual(CoreRead.json(report), "null")

        let older = await CoreTrainingReports.cardio(reader: reader, maxHR: 190, sex: "male",
            days: -1, weekOffset: -100, now: now)
        XCTAssertEqual(older.selection.days, 120, "unsupported windows use the Apple default")
        XCTAssertEqual(older.selection.weekOffset, -3)
        XCTAssertEqual(older.weekSessions, 1)

        let load = await CoreTrainingLoad.read(reader: reader, maxHR: 190, sex: "male",
                                               dismissedWorkoutSpans: [], now: now)
        XCTAssertEqual(load.recoveryState, "holding")
        XCTAssertGreaterThan(load.nightsRead, 0, "Training Load must read computed physiology, not only imports")
    }
}
