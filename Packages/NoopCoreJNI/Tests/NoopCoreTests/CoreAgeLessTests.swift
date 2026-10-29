import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// AgeLess on Android (parity plan 2.3): the core reads the stored week through the shared snapshot and hands the
/// screen every resolved number.
@MainActor
final class CoreAgeLessTests: XCTestCase {
    func testStoredWeekIsPricedWithItsMeasures() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let now = Date()
        let day = StoreReader.localDayKey(now.addingTimeInterval(-2 * 86_400))
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: day, key: DailyAnalysis.healthspanAgeKey, value: 38),
            MetricPoint(day: day, key: DailyAnalysis.healthspanInputKey(.sleepDuration), value: 6.5),
            MetricPoint(day: day, key: DailyAnalysis.healthspanInputKey(.dailySteps), value: 6_000),
            MetricPoint(day: day, key: DailyAnalysis.healthspanInputKey(.restingHR), value: 62),
            MetricPoint(day: day, key: DailyAnalysis.healthspanCoveredDaysKey, value: 40),
        ], deviceId: "my-whoop-noop")

        let none = await CoreAgeLess.snapshot(reader: reader, age: 0, sex: "male", now: now)
        XCTAssertTrue(none.weeks.isEmpty)
        let output = await CoreAgeLess.snapshot(reader: reader, age: 40, sex: "male", now: now)
        let week = try XCTUnwrap(output.weeks.last)
        XCTAssertEqual(week.day, day)
        XCTAssertEqual(week.actualAge, 40)
        XCTAssertTrue(week.provisional)
        XCTAssertEqual(week.domains.map(\.domain), ["sleep", "activity", "fitness"])
        let steps = try XCTUnwrap(week.domains.flatMap(\.measures).first { $0.component == "dailySteps" })
        XCTAssertEqual(steps.value, 6_000)
        XCTAssertNotNil(steps.position)
        XCTAssertFalse(week.levers.isEmpty)
        XCTAssertEqual(week.delta, week.age - week.actualAge, accuracy: 1e-9)
    }
}

/// The daily-rhythm readout on Android (parity plan 2.3): a stored reading crosses with its words resolved.
@MainActor
final class CoreRhythmAgeTests: XCTestCase {
    func testStoredReadingCrossesWithItsWords() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let now = Date()
        let day = StoreReader.localDayKey(now.addingTimeInterval(-86_400))
        let empty = await CoreRhythmAge.snapshot(reader: reader, now: now)
        XCTAssertEqual(empty.state, "empty")
        var points = [MetricPoint(day: day, key: DailyAnalysis.rhythmHoursKey, value: 160),
                      MetricPoint(day: day, key: DailyAnalysis.rhythmAdvanceKey, value: 2.5),
                      MetricPoint(day: day, key: DailyAnalysis.rhythmMesorKey, value: 20),
                      MetricPoint(day: day, key: DailyAnalysis.rhythmAmplitudeKey, value: 15),
                      MetricPoint(day: day, key: DailyAnalysis.rhythmPeakKey, value: 14)]
        for h in 0..<24 { points.append(MetricPoint(day: day, key: DailyAnalysis.rhythmHourKey(h), value: Double(h % 12) * 3)) }
        _ = try await store.upsertMetricSeries(points, deviceId: "my-whoop-noop")
        let output = await CoreRhythmAge.snapshot(reader: reader, now: now)
        XCTAssertEqual(output.state, "reading")
        XCTAssertEqual(output.advance, 2.5)
        XCTAssertEqual(output.hourly.count, 24)
        XCTAssertEqual(output.typical.count, 24)
        XCTAssertNotNil(output.lever)
        XCTAssertEqual(output.history.map(\.advance), [2.5])
    }
}
