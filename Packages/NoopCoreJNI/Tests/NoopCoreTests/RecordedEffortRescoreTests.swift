import XCTest
import StrandAnalytics
import StrandCore
import WhoopProtocol
import WhoopStore
@testable import NoopCore

/// The rebuild scores the Effort stored on a recorded or confirmed strap workout again from the band's trace,
/// against its day's Effort resting heart rate (`WorkoutHeartRateFills.rescoreRecordedEffort`). Such a value was
/// stored when the session was saved and followed no later change to how Effort is scored (2026-11-25).
final class RecordedEffortRescoreTests: XCTestCase {

    private func row(_ start: Int, minutes: Int, source: String, strain: Double?) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: "Walking", source: source,
                   durationS: Double(minutes * 60), energyKcal: nil, avgHr: 120, maxHr: 130, strain: strain,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    func testARecordedWalkIsScoredAgainOnItsDaysEffortRestingRate() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let start = Int(Date().timeIntervalSince1970) - 2 * 86_400
        let day = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(start)))
        try await store.insert(Streams(hr: (0 ..< 40 * 60).map { HRSample(ts: start + $0, bpm: 120) }),
                               deviceId: "my-whoop")
        _ = try await store.upsertMetricSeries([MetricPoint(day: day, key: EffortRestingHR.seriesKey, value: 66)],
                                               deviceId: "my-whoop-noop")
        let recorded = row(start, minutes: 40, source: "manual", strain: 40)
        let confirmed = row(start + 6 * 3600, minutes: 30, source: WorkoutSource.confirmedSuggestionSource,
                            strain: 30)       // no band trace: cannot be scored, keeps its value
        _ = try await store.upsertWorkouts([recorded, confirmed], deviceId: "my-whoop")
        let imported = row(start, minutes: 40, source: "apple-health", strain: 25)
        _ = try await store.upsertWorkouts([imported], deviceId: MetricResolver.appleHealthSource)

        let rescored = try await WorkoutHeartRateFills.rescoreRecordedEffort(reader: reader, from: start - 60,
                                                                             to: start + 86_400, maxHR: 190)
        XCTAssertEqual(rescored, 1)
        let rows = try await store.workouts(deviceId: "my-whoop", from: start - 60, to: start + 86_400,
                                            limit: 10, offset: 0)
        let expected = try XCTUnwrap(WorkoutHeartRateFill.resolve(
            band: (0 ..< 40 * 60).map { HRSample(ts: start + $0, bpm: 120) }, watchMinutes: [],
            start: start, end: start + 40 * 60, maxHR: 190, restingHR: 66)?.strain)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.startTs == start }?.strain), expected, accuracy: 1e-9)
        XCTAssertNotEqual(expected, 40)
        XCTAssertEqual(rows.first { $0.startTs == start + 6 * 3600 }?.strain, 30)
        let apple = try await store.workouts(deviceId: MetricResolver.appleHealthSource, from: start - 60,
                                             to: start + 60, limit: 10, offset: 0)
        XCTAssertEqual(apple.first?.strain, 25, "an import keeps what its source gave it")

        let again = try await WorkoutHeartRateFills.rescoreRecordedEffort(reader: reader, from: start - 60,
                                                                          to: start + 86_400, maxHR: 190)
        XCTAssertEqual(again, 0, "a second run finds nothing to change")
    }
}
