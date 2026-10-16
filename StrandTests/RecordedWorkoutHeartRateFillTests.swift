import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// A workout recorded in NOOP takes its heart rate from the live stream. When the strap link was down while it
/// ran, the row is saved without average, peak or Effort, although the strap kept its own trace and handed it
/// over at the next sync. The list already shows average and peak from that trace (#77/#499, display only),
/// but nothing supplied the Effort. The fill stores all three from the trace, as it does for Apple Health
/// workouts, so every reader sees them.
@MainActor
final class RecordedWorkoutHeartRateFillTests: XCTestCase {

    private let strap = "my-whoop"
    private let start = 1_792_130_000
    private var end: Int { start + 30 * 60 }

    private func makeRepo() async throws -> (Repository, WhoopStore) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorded-fill-\(UUID().uuidString).sqlite").path
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let store = try await WhoopStore(path: path)
        let repo = Repository(deviceId: strap)
        repo.setStoreForTesting(store)
        return (repo, store)
    }

    private func recordedRow(avgHr: Int? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: "walking", source: "manual", durationS: Double(end - start),
                   energyKcal: nil, avgHr: avgHr, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil,
                   notes: nil, steps: nil)
    }

    /// Every second of the session at 110 bpm, with one 140 bpm peak.
    private func insertTrace(_ store: WhoopStore, coverage: Double = 1) async throws {
        var streams = Streams.empty
        let last = start + Int(Double(end - start) * coverage)
        for ts in start..<last { streams.hr.append(HRSample(ts: ts, bpm: ts == start + 600 ? 140 : 110)) }
        try await store.insert(streams, deviceId: strap)
    }

    /// A resting rate for the session's day, so Effort can be scored.
    private func insertRestingHR(_ store: WhoopStore) async throws {
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(start)))
        _ = try await store.upsertDailyMetrics([DailyMetric(
            day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 60, avgHrv: nil, recovery: nil, strain: nil,
            exerciseCount: nil, steps: nil)], deviceId: strap + "-noop")
    }

    func testARecordedWorkoutWithoutHeartRateGetsItsEffortFromTheStrapTrace() async throws {
        let (repo, store) = try await makeRepo()
        _ = try await store.upsertWorkouts([recordedRow()], deviceId: strap)
        try await insertTrace(store)
        try await insertRestingHR(store)
        let filled = try await repo.fillRecordedWorkoutHeartRate(from: start - 60, to: end + 60)
        XCTAssertEqual(filled, 1)
        let fill = await repo.workoutHeartRateFill(for: recordedRow())
        XCTAssertEqual(fill?.avgHr, 110)
        XCTAssertEqual(fill?.maxHr, 140)
        let row = await repo.workoutRows(days: 4000).first { $0.startTs == start }
        XCTAssertNotNil(row?.strain, "the saved row had no Effort; the trace supplies it")
    }

    func testAWorkoutRecordedWithHeartRateIsNotFilled() async throws {
        let (repo, store) = try await makeRepo()
        _ = try await store.upsertWorkouts([recordedRow(avgHr: 99)], deviceId: strap)
        try await insertTrace(store)
        let filled = try await repo.fillRecordedWorkoutHeartRate(from: start - 60, to: end + 60)
        XCTAssertEqual(filled, 0)
        let fill = await repo.workoutHeartRateFill(for: recordedRow(avgHr: 99))
        XCTAssertNil(fill)
    }

    func testATraceCoveringTooLittleOfTheSessionStoresNoFill() async throws {
        let (repo, store) = try await makeRepo()
        _ = try await store.upsertWorkouts([recordedRow()], deviceId: strap)
        try await insertTrace(store, coverage: 0.3)
        let filled = try await repo.fillRecordedWorkoutHeartRate(from: start - 60, to: end + 60)
        XCTAssertEqual(filled, 0)
        let fill = await repo.workoutHeartRateFill(for: recordedRow())
        XCTAssertNil(fill)
    }
}
