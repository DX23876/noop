import XCTest
import StrandAnalytics
import WhoopProtocol
import StrandCore
import WhoopStore
@testable import Strand

@MainActor
final class AnalysisRecipeDecisionTests: XCTestCase {
    func testAI29RebuildsOnlyTheAgeLessWeeks() {
        XCTAssertTrue(AnalysisRecipe.migrationRebuildsHealthspan(from: 28, to: 29))
        XCTAssertFalse(AnalysisRecipe.migrationRebuildsHealthspan(from: 29, to: 29))
        XCTAssertTrue(AnalysisRecipe.migrationRebuildsHealthspan(from: 27, to: 29))
        XCTAssertTrue(AnalysisRecipe.migrationRepairsStressProxy(from: 27, to: 29))
        XCTAssertFalse(AnalysisRecipe.migrationRepairsStressProxy(from: 28, to: 29))
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 28), 0)
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 28, to: 29))
        XCTAssertFalse(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 28, to: 29))
        XCTAssertFalse(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 28, to: 29))
        let keys = Set(IntelligenceEngine.healthspanWeeklyKeys)
        XCTAssertTrue(keys.contains(IntelligenceEngine.healthspanGapNightsKey))
        XCTAssertTrue(keys.contains(IntelligenceEngine.healthspanGapMissingKey))
    }

    func testAI26RebuildsOnlyTheAgeLessWeeks() {
        XCTAssertTrue(AnalysisRecipe.migrationRebuildsHealthspan(from: 25, to: 26))
        XCTAssertFalse(AnalysisRecipe.migrationRebuildsHealthspan(from: 27, to: 27))
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 25), 0)
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 25, to: 26))
        XCTAssertFalse(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 25, to: 26))
        XCTAssertTrue(IntelligenceEngine.healthspanWeeklyKeys.contains(IntelligenceEngine.healthspanVO2FloorKey))
    }

    func testAI21ToAI24RebuildOnlyTheAgeLessWeeks() {
        XCTAssertTrue(AnalysisRecipe.migrationRebuildsHealthspan(from: 20, to: 24))
        XCTAssertTrue(AnalysisRecipe.migrationRebuildsHealthspan(from: 21, to: 24))
        XCTAssertTrue(AnalysisRecipe.migrationRebuildsHealthspan(from: 22, to: 24))
        XCTAssertTrue(AnalysisRecipe.migrationRebuildsHealthspan(from: 23, to: 24))
        XCTAssertTrue(AnalysisRecipe.migrationRebuildsHealthspan(from: 8, to: 24))
        XCTAssertFalse(AnalysisRecipe.migrationRebuildsHealthspan(from: 27, to: 27))
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 23), 0)
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 22), 0)
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 21), 0)
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 20), 0)
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 20, to: 21))
        XCTAssertFalse(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 20, to: 21))
        XCTAssertFalse(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 20, to: 21))
        // The rebuild clears the weeks but keeps what cannot be recomputed: banked zone and VO₂max days.
        let keys = Set(IntelligenceEngine.healthspanWeeklyKeys)
        XCTAssertTrue(keys.contains(IntelligenceEngine.healthspanAgeKey))
        XCTAssertFalse(keys.contains(IntelligenceEngine.healthspanZone13Key))
        XCTAssertFalse(keys.contains(IntelligenceEngine.healthspanLegacyTrainingVO2Key))
        // AI-23's basis keys go with the weeks, so a rebuild cannot leave a stale count behind.
        XCTAssertTrue(keys.contains(IntelligenceEngine.healthspanCountKey(.dailySteps)))
        XCTAssertTrue(keys.contains(IntelligenceEngine.healthspanVO2DayKey))
        XCTAssertTrue(keys.contains(IntelligenceEngine.healthspanBodyFatDayKey))
    }

    /// AI-13 and AI-14 read the resting rate from imported daily rows, which end at the last WHOOP
    /// export. A figure the live save priced with the day's measured rate (NOOP's computed row) then
    /// failed to reproduce and kept its Keytel value. The correction must read the computed row.
    func testLegacyCorrectionUsesTheComputedRestingRate() async throws {
        let store = try await WhoopStore.inMemory()
        let active = "whoop-a"
        let repo = Repository(deviceId: active)
        repo.setStoreForTesting(store)
        let profile = UserProfile(weightKg: 212, heightCm: 196, age: 35, sex: "male", maxHR: 195)
        let start = Int(Date().timeIntervalSince1970) - 20_000
        let hr = (0..<3_600).map { HRSample(ts: start + $0, bpm: 140) }
        try await store.insert(Streams(hr: hr), deviceId: active)
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(start)))
        _ = try await store.upsertDailyMetrics([
            DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: 50, avgHrv: nil,
                        recovery: nil, strain: nil, exerciseCount: nil)
        ], deviceId: active + "-noop")
        let stored = Calories.estimateBoutCalories(hr, profile: profile, hrmax: 195, restingHR: 50).0
        let withoutResting = Calories.estimateBoutCalories(hr, profile: profile, hrmax: 195, restingHR: nil).0
        XCTAssertGreaterThan(abs(stored - withoutResting), LegacyWorkoutEnergy.tolerance * withoutResting,
                             "precondition: without the resting rate the figure must not reproduce")
        // Indoor, so no distance and no live-summary witness: only the resting rate can recognise it.
        try await store.upsertWorkouts([
            WorkoutRow(startTs: start, endTs: start + 3_600, sport: "Indoor cycle", source: "manual",
                       durationS: 3_600, energyKcal: stored, avgHr: 140, maxHr: 150, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        ], deviceId: "my-whoop")

        let corrected = try await repo.correctLegacyWorkoutEnergy(profile: profile)
        XCTAssertEqual(corrected, start)
        let rows = try await store.workouts(deviceId: "my-whoop", from: start, to: start, limit: 1)
        let expected = WorkoutEnergyEstimate.boutKcal(hr, sport: "Indoor cycle", profile: profile,
                                                      hrMax: 195, restingHR: 50, peakMET: nil,
                                                      distanceM: nil)
        XCTAssertEqual(rows.first?.energyKcal ?? 0, expected, accuracy: 0.001)
    }

    /// AI-13 and AI-14 also PRICED their corrections without the resting rate. A row they marked
    /// computed is NOOP's own figure, so AI-15 prices it again; an entered one is never touched.
    func testComputedRowsArePricedAgainAndEnteredRowsKept() async throws {
        let store = try await WhoopStore.inMemory()
        let active = "whoop-b"
        let repo = Repository(deviceId: active)
        repo.setStoreForTesting(store)
        let profile = UserProfile(weightKg: 212, heightCm: 196, age: 35, sex: "male", maxHR: 195)
        let start = Int(Date().timeIntervalSince1970) - 30_000
        let other = start + 7_200
        let hr = (0..<3_600).map { HRSample(ts: start + $0, bpm: 120) }
            + (0..<3_600).map { HRSample(ts: other + $0, bpm: 120) }
        try await store.insert(Streams(hr: hr), deviceId: active)
        func row(_ ts: Int) -> WorkoutRow {
            WorkoutRow(startTs: ts, endTs: ts + 3_600, sport: "Indoor cycle", source: "manual",
                       durationS: 3_600, energyKcal: 5_000, avgHr: 120, maxHr: 130, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        }
        try await store.upsertWorkouts([row(start), row(other)], deviceId: "my-whoop")
        try await store.setWorkoutEnergySource(
            .computed, for: WorkoutKey(deviceId: "my-whoop", startTs: start, sport: "Indoor cycle"))
        try await store.setWorkoutEnergySource(
            .entered, for: WorkoutKey(deviceId: "my-whoop", startTs: other, sport: "Indoor cycle"))

        let corrected = try await repo.correctLegacyWorkoutEnergy(profile: profile)
        XCTAssertEqual(corrected, start)
        let rows = try await store.workouts(deviceId: "my-whoop", from: start, to: other, limit: 5)
        let kcal = Dictionary(uniqueKeysWithValues: rows.map { ($0.startTs, $0.energyKcal ?? 0) })
        XCTAssertLessThan(kcal[start] ?? 0, 5_000)
        XCTAssertGreaterThan(kcal[start] ?? 0, 0)
        XCTAssertEqual(kcal[other], 5_000)
        let again = try await repo.correctLegacyWorkoutEnergy(profile: profile)
        XCTAssertNil(again, "an unchanged price is not rewritten")
    }

    func testLegacyCorrectionFindsCanonicalWorkoutUnderAnotherActiveStrap() async throws {
        let store = try await WhoopStore.inMemory()
        let active = "whoop-readded"
        let repo = Repository(deviceId: active)
        repo.setStoreForTesting(store)
        let profile = UserProfile(weightKg: 212, heightCm: 196, age: 35, sex: "male", maxHR: 195)
        let start = Int(Date().timeIntervalSince1970) - 10_000
        let duration = 3_600.0
        let old = Calories.estimateBoutCalories(averageHR: 147, durationSeconds: duration,
                                               profile: profile, hrmax: 195, restingHR: nil)!
        let row = WorkoutRow(startTs: start, endTs: start + Int(duration), sport: "Walking",
                             source: "manual", durationS: duration, energyKcal: old, avgHr: 147,
                             maxHr: 165, strain: nil, distanceM: 4_000, zonesJSON: nil,
                             notes: "keep me", steps: nil)
        try await store.upsertWorkouts([row], deviceId: "my-whoop")
        let hr = (0..<Int(duration)).map { HRSample(ts: start + $0, bpm: 60) }
        try await store.insert(Streams(hr: hr), deviceId: active)

        let corrected = try await repo.correctLegacyWorkoutEnergy(profile: profile)
        XCTAssertEqual(corrected, start)
        let updated = try await store.workouts(deviceId: "my-whoop", from: start, to: start, limit: 1)
        XCTAssertEqual(updated.count, 1)
        XCTAssertNotEqual(updated[0].energyKcal, old)
        XCTAssertEqual(updated[0].notes, "keep me")
        let key = WorkoutKey(deviceId: "my-whoop", startTs: start, sport: "Walking")
        let sources = try await store.workoutEnergySources(deviceId: "my-whoop", from: start, to: start)
        XCTAssertEqual(sources[key], .computed)
        let repeated = try await repo.correctLegacyWorkoutEnergy(profile: profile)
        XCTAssertNil(repeated,
                     "the provenance marker makes the migration resumable")
    }

    // MARK: - The fork's own recipe lineage

    /// An install from before the rename keeps its place: its legacy AI-8 is adopted, so it owes only
    /// AI-9 — the ledger refill — and no daily re-score from 0.
    func testAPreRenameInstallAdoptsItsRecipe() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("recipe-rename-\(UUID().uuidString).sqlite").path
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let store = try await WhoopStore(path: path)
        try await store.setCursor(AnalysisRecipe.legacyCursor, 8)
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "my-whoop")
        let ok = await engine.prepareAnalysisRecipe()
        XCTAssertTrue(ok)
        let migrated = try await store.cursor(AnalysisRecipe.cursor)
        XCTAssertEqual(migrated, AnalysisRecipe.currentVersion)
        let legacy = try await store.cursor(AnalysisRecipe.legacyCursor)
        XCTAssertEqual(legacy, 8, "the legacy cursor is read, never written")
    }
}
