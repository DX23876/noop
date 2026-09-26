import XCTest
import StrandAnalytics
import StrandTraining
import WhoopProtocol
import WhoopStore
@testable import Strand

/// The reported case end to end: a 90-minute strength session logged in the native logger while the
/// strap recorded its heart rate. The strap energy model read its workout context from a list of
/// storage namespaces that had no native training tables in it, so the session's buckets were priced
/// as heart rate without activity — zero active kcal — while the workout tile, with no figure to read,
/// fell to Keytel at the average heart rate. The day's "Training" line and the tile disagreed by 4×.
@MainActor
final class NativeWorkoutEnergyContextTests: XCTestCase {
    private let strap = "my-whoop"
    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")

    func testANativeSessionIsTheWorkoutContextAndItsTileReadsTheStrapModel() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: strap)
        repo.setStoreForTesting(store)

        let now = Int(Date().timeIntervalSince1970)
        let start = (now - 3 * 3_600) / 300 * 300
        let end = start + 5_400
        // Lifting: work sets around 120 bpm, rests around 100, one sample a second.
        let hr = (start..<end).map { ts in HRSample(ts: ts, bpm: (ts - start) % 180 < 60 ? 122 : 100) }
        _ = try await store.insert(Streams(hr: hr), deviceId: strap)

        // Before the session exists, the model can only call it unexplained heart rate.
        await repo.refreshWhoopEnergyModel(days: 2, profile: profile)
        let activeBefore = try await activeKcal(store, from: start, to: end)
        XCTAssertEqual(activeBefore, 0, accuracy: 1e-9)

        let workout = NativeWorkout(id: UUID(), title: "Shoulder & Legs", startedAt: start, endedAt: end,
                                    plannedDay: Repository.localDayKey(Date(timeIntervalSince1970:
                                        TimeInterval(start))),
                                    routineIds: [], exercises: [], tracker: nil)
        try await store.completeNativeWorkout(workout)
        let row = NativeTrainingProjection.workoutRow(workout)
        let staleAnswer = await repo.strapSessionEnergy(for: [row])
        XCTAssertTrue(staleAnswer.isEmpty, "buckets priced before the session was saved must not answer for it")

        await repo.refreshWhoopEnergyModel(days: 2, profile: profile)
        let buckets = try await windowBuckets(store, from: start, to: end)
        XCTAssertFalse(buckets.isEmpty)
        XCTAssertTrue(buckets.allSatisfy { $0.context == EnergyContext.confirmedWorkout.rawValue },
                      "every bucket inside a logged session is priced as that workout")
        let activeAfter = try await activeKcal(store, from: start, to: end)
        XCTAssertGreaterThan(activeAfter, 0)

        let answered = await repo.strapSessionEnergy(for: [row])
        let strapKcal = try XCTUnwrap(answered[WorkoutEnergyDisplay.key(row)])
        let resolved = WorkoutEnergyDisplay.resolve(row, profile: profile, hrMax: nil, restingHrByDay: [:],
                                                    strapKcalByKey: [WorkoutEnergyDisplay.key(row): strapKcal])
        XCTAssertEqual(resolved?.provenance, .strapModel)
        // Gross: the window's own basal plus its active energy, i.e. more than the active share alone.
        XCTAssertGreaterThan(strapKcal, activeAfter)
    }

    private func windowBuckets(_ store: WhoopStore, from: Int, to: Int) async throws -> [WhoopEnergyBucketRow] {
        var days = Set<String>()
        for ts in [from, to - 1] {
            days.insert(Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(ts))))
        }
        var rows: [WhoopEnergyBucketRow] = []
        for day in days { rows += try await store.whoopEnergyBuckets(deviceId: strap, day: day) }
        return rows.filter { $0.bucketStart >= from && $0.bucketStart < to }
    }

    private func activeKcal(_ store: WhoopStore, from: Int, to: Int) async throws -> Double {
        try await windowBuckets(store, from: from, to: to).reduce(0) { $0 + $1.activeKcal }
    }
}
