import XCTest
@testable import Strand
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// AI-16: Apple Health workouts get the average, peak and Effort their source left out, from the Watch's
/// own minutes when the band did not cover them; WHOOP's copies in Health stay as they came; a filled value
/// never decides which twin stands for a session; and a cardio-load row priced before the trace arrived is
/// freed to be priced again.
@MainActor
final class AppleWorkoutHeartRateFillTests: XCTestCase {

    private let apple = Repository.appleHealthSource

    private func walk(_ start: Int, minutes: Int = 40) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: "Walking", source: apple,
                   durationS: Double(minutes * 60), energyKcal: 250, avgHr: nil, maxHr: nil, strain: nil,
                   distanceM: 3_000, zonesJSON: nil, notes: nil, steps: nil)
    }

    private func seed(_ store: WhoopStore, row: WorkoutRow, key: String, bundle: String,
                      bpm: Double = 120, steps: Int? = nil) async throws {
        try await store.upsertWorkouts([row], deviceId: apple)
        try await store.upsertWorkoutSourceMetadata([
            WorkoutSourceMetadataRow(componentKey: key, source: apple, startTs: row.startTs, sport: row.sport,
                                     externalId: key, sourceBundleId: bundle, rawActivityType: 52,
                                     activitiesJSON: nil, updatedAtTs: 1, steps: steps),
        ])
        let minutes = (row.endTs - row.startTs) / 60
        try await store.replaceWorkoutHeartRateBuckets(componentKey: key, rows: (0..<minutes).map {
            WorkoutHeartRateBucketRow(componentKey: key, bucketStart: row.startTs + $0 * 60,
                                      bpm: bpm + Double($0 % 3), sourceBundleId: bundle)
        })
    }

    private func setUpRepo() async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "whoop-fill")
        repo.setStoreForTesting(store)
        repo.strainProfile = .init(hrMax: 190, sex: "male")
        return (repo, store)
    }

    func testWatchMinutesFillAnAppleWalkAndWhoopCopiesAreLeftAlone() async throws {
        let (repo, store) = try await setUpRepo()
        let start = Int(Date().timeIntervalSince1970) - 5 * 86_400
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(start)))
        try await seed(store, row: walk(start), key: "apple-health|watch", bundle: "com.apple.Fitness",
                       steps: 4_200)
        try await seed(store, row: walk(start + 20_000), key: "apple-health|whoop", bundle: "com.whoop.iphone")
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: 62, avgHrv: nil,
                        recovery: nil, strain: nil, exerciseCount: nil),
        ], deviceId: apple)

        let filled = try await repo.fillAppleWorkoutHeartRate(from: 0, to: start + 86_400)
        XCTAssertEqual(filled, 1)

        let rows = await repo.workoutRows(days: 30, reconcileHrCap: 0)
        let watchRow = try XCTUnwrap(rows.first { $0.startTs == start })
        XCTAssertEqual(watchRow.avgHr, 121)
        XCTAssertEqual(watchRow.maxHr, 122)
        XCTAssertNotNil(watchRow.strain, "a Watch resting rate on the day lets Effort be scored")
        XCTAssertEqual(watchRow.steps, 4_200, "Health's steps for the workout ride on the source metadata")
        let whoopRow = try XCTUnwrap(rows.first { $0.startTs == start + 20_000 })
        XCTAssertNil(whoopRow.avgHr, "a WHOOP copy keeps the empty fields it came with")

        let fill = await repo.workoutHeartRateFill(for: walk(start))
        XCTAssertEqual(fill?.hrSource, "watch")
        XCTAssertEqual(fill?.restingHrUsed, 62)
    }

    /// Without a resting rate for the day, the averages are filled and Effort is not.
    func testNoRestingRateMeansAveragesWithoutEffort() async throws {
        let (repo, store) = try await setUpRepo()
        let start = Int(Date().timeIntervalSince1970) - 3 * 86_400
        try await seed(store, row: walk(start), key: "apple-health|a", bundle: "com.apple.Fitness")
        _ = try await repo.fillAppleWorkoutHeartRate(from: 0, to: start + 86_400)
        let rows = await repo.workoutRows(days: 30, reconcileHrCap: 0)
        let row = try XCTUnwrap(rows.first { $0.startTs == start })
        XCTAssertEqual(row.avgHr, 121)
        XCTAssertNil(row.strain)
    }

    /// The strap's own recording of the same walk stays the entry that represents it, even though filling
    /// makes the Apple twin carry more fields than it did.
    func testAFilledValueNeverDecidesWhichTwinStandsForTheSession() async throws {
        let (repo, store) = try await setUpRepo()
        let start = Int(Date().timeIntervalSince1970) - 4 * 86_400
        try await seed(store, row: walk(start), key: "apple-health|twin", bundle: "com.apple.Fitness")
        try await store.upsertWorkouts([
            WorkoutRow(startTs: start + 30, endTs: start + 40 * 60, sport: "Walking", source: "manual",
                       durationS: 2_370, energyKcal: nil, avgHr: 118, maxHr: 140, strain: 25,
                       distanceM: nil, zonesJSON: nil, notes: nil, steps: nil),
        ], deviceId: "whoop-fill")
        _ = try await repo.fillAppleWorkoutHeartRate(from: 0, to: start + 86_400)
        let rows = await repo.workoutRows(days: 30, reconcileHrCap: 0)
        let shown = rows.filter { abs($0.startTs - start) < 600 }
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.source, "manual")
    }

    /// A session the cardio load priced before its Watch trace arrived is freed to be priced again.
    func testALoadPricedWithoutATraceIsFreedByTheFill() async throws {
        let (repo, store) = try await setUpRepo()
        let start = Int(Date().timeIntervalSince1970) - 40 * 86_400
        try await seed(store, row: walk(start), key: "apple-health|old", bundle: "com.apple.Fitness")
        try await store.upsertTrainingSessionLoads([
            TrainingSessionLoadRow(sessionId: "s", method: Repository.cardioLoadMethod,
                                   methodVersion: Repository.cardiovascularLoadRecipeVersion,
                                   startTs: start, endTs: start + 2_400, trimp: nil, effort: nil,
                                   hrSource: "none", coveredMinutes: 0, possibleMinutes: 40, hrmaxUsed: 190,
                                   restingHrUsed: 60, inputFingerprint: "f", computedAtTs: start + 30 * 86_400),
        ])
        _ = try await repo.fillAppleWorkoutHeartRate(from: 0, to: start + 86_400)
        let left = try await store.trainingSessionLoads(from: 0, to: Int.max, method: Repository.cardioLoadMethod,
                                                        methodVersion: Repository.cardiovascularLoadRecipeVersion)
        XCTAssertTrue(left.isEmpty)
    }
}
