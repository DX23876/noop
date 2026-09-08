import XCTest
import WhoopStore
import WhoopProtocol
import StrandAnalytics
@testable import Strand

@MainActor
final class DayCycleWorkerTests: XCTestCase {
    @MainActor private final class Gate {
        let started = XCTestExpectation(description: "worker entered reader")
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        func finish() { continuation?.resume(); continuation = nil }
    }

    func testQueuedCancellationDoesNotInterleaveAnalysisOrBlockLaterWork() async throws {
        let store = try await WhoopStore.inMemory()
        let worker = DayCycleIntelligenceIntegration()
        let gate = Gate()
        let reader = DayCycleIntelligenceIntegration.BoundaryRecoveryReader(
            sleepSessions: { _, _, _ in
                XCTAssertFalse(Thread.isMainThread, "analysis reader is running on the UI thread")
                await gate.wait()
                return []
            }, markers: { _, _, _ in [] })
        let first = Task { try await compute(worker, store: store, reader: reader) }
        await fulfillment(of: [gate.started], timeout: 2)
        let queued = expectation(description: "second request queued")
        let second = Task {
            queued.fulfill()
            return try await compute(worker, store: store, reader: .init(
                sleepSessions: { _, _, _ in XCTFail("cancelled queued request performed I/O"); return [] },
                markers: { _, _, _ in [] }))
        }
        await fulfillment(of: [queued], timeout: 2)
        second.cancel()
        gate.finish()
        _ = try await first.value
        do { _ = try await second.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
        let result = try await compute(worker, store: store, reader: .init(
            sleepSessions: { _, _, _ in [] }, markers: { _, _, _ in [] }))
        XCTAssertTrue(result.onsetByWakeDay.isEmpty)
    }

    func testWorkerKeepsStrainCaloriesAndWindowBoundariesIdentical() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "strap", mac: nil, name: "WHOOP")
        let start = 1_788_213_600 // A fixed ten-hour window, independent of wall clock / local timezone.
        let samples = (0..<600).map { HRSample(ts: start + $0 * 60, bpm: $0 < 480 ? 60 : 130) }
        try await store.insert(Streams(hr: samples), deviceId: "strap")
        let day = AnalyticsEngine.dayString(start + 8 * 3600, offsetSec: 0)
        let row = DailyMetric(day: day, totalSleepMin: 480, efficiency: 90,
            deepMin: 90, remMin: 90, lightMin: 300, disturbances: nil,
            restingHr: 52, avgHrv: 60, recovery: 70, strain: nil,
            exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
        let night = CachedSleepSession(startTs: start, endTs: start + 8 * 3600,
            efficiency: 90, restingHr: 52, avgHrv: 60,
            stagesJSON: "{\"light\":300,\"deep\":90,\"rem\":90,\"awake\":0}")
        let profile = UserProfile()
        let worker = DayCycleIntelligenceIntegration()
        for _ in 0..<2 {
            let result = try await worker.compute(nights: [.init(daily: row, sleeps: [night], workouts: [], owner: "strap")],
                editedRows: [], store: store, candidates: [(owner: "strap", priority: 0)],
                physiologyOwners: ["strap"], workouts: [], windowStart: start, now: start + 10 * 3600,
                offsetSec: 0, habitualMidsleepSec: nil, ticksPerStep: 1, mode: .sleepOnset,
                profile: profile, maxHROverride: 190, effortMethod: .edwards,
                recoveryReader: .init(sleepSessions: { _, _, _ in [] }, markers: { _, _, _ in [] }))
            let expectedStrain = StrainScorer.strain(samples, maxHR: 190, restingHR: 52,
                                                    method: .edwards, sex: profile.sex)
            XCTAssertEqual(result.strainByWakeDay[day], expectedStrain)
            XCTAssertEqual(result.caloriesByWakeDay[day], Calories.estimateDayCalories(samples,
                profile: profile, hrmax: 190, restingHR: 52))
            XCTAssertEqual(result.onsetByWakeDay[day], start)
            XCTAssertEqual(result.workoutCountByWakeDay[day], 0)
        }
    }

    func testFingerprintReusedNightKeepsPersistedActivityWithoutRawHRRead() async throws {
        let store = try await WhoopStore.inMemory()
        let start = 1_788_213_600
        let day = AnalyticsEngine.dayString(start + 8 * 3600, offsetSec: 0)
        let row = DailyMetric(day: day, totalSleepMin: 480, efficiency: 90,
            deepMin: 90, remMin: 90, lightMin: 300, disturbances: nil,
            restingHr: 52, avgHrv: 60, recovery: 70, strain: 12.5,
            exerciseCount: 4, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil,
            activeKcalEst: 1_845)
        let sleep = CachedSleepSession(startTs: start, endTs: start + 8 * 3600,
            efficiency: 90, restingHr: 52, avgHrv: 60,
            stagesJSON: "{\"light\":300,\"deep\":90,\"rem\":90,\"awake\":0}")

        let result = try await DayCycleIntelligenceIntegration().compute(
            nights: [.init(daily: row, sleeps: [sleep], workouts: [], owner: "strap", reused: true)],
            editedRows: [], store: store, candidates: [(owner: "strap", priority: 0)],
            physiologyOwners: ["strap"], workouts: [], windowStart: start,
            now: start + 10 * 3600, offsetSec: 0, habitualMidsleepSec: nil,
            ticksPerStep: 1, mode: .sleepOnset, profile: UserProfile(),
            maxHROverride: 190, effortMethod: .edwards,
            recoveryReader: .init(sleepSessions: { _, _, _ in [] }, markers: { _, _, _ in [] }))

        XCTAssertEqual(result.strainByWakeDay[day], 12.5)
        XCTAssertEqual(result.caloriesByWakeDay[day], 1_845)
        XCTAssertEqual(result.workoutCountByWakeDay[day], 4)
    }

    private func compute(_ worker: DayCycleIntelligenceIntegration, store: WhoopStore,
                         reader: DayCycleIntelligenceIntegration.BoundaryRecoveryReader) async throws -> DayCycleIntelligenceIntegration.Result {
        try await worker.compute(nights: [], editedRows: [], store: store,
            candidates: [(owner: "strap", priority: 0)], physiologyOwners: ["strap"], workouts: [],
            windowStart: 1_700_000_000, now: 1_700_086_400, offsetSec: 0, habitualMidsleepSec: nil,
            ticksPerStep: 1, mode: .sleepOnset, profile: UserProfile(),
            maxHROverride: nil, effortMethod: .edwards, recoveryReader: reader)
    }
}
