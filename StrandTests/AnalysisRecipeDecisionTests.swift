import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class AnalysisRecipeDecisionTests: XCTestCase {
    func testExistingInstallWithoutCursorAnchorsWithoutReanalysis() {
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: nil), .anchorCurrent)
    }

    func testCurrentAndFutureRecipesDoNotReanalyze() {
        let current = IntelligenceEngine.currentAnalysisRecipeVersion
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: current), .upToDate)
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: current + 1), .upToDate)
    }

    func testOlderRecipeRequestsExplicitMigration() {
        let current = IntelligenceEngine.currentAnalysisRecipeVersion
        XCTAssertEqual(
            IntelligenceEngine.analysisRecipeDecision(storedVersion: current - 1),
            .migrate(from: current - 1, to: current))
    }

    /// The tests above are written against `current`, so they stay green through a bump without ever
    /// witnessing one. This one names AI-19, the Apple Health projection/provenance repair, and
    /// requires every older stored recipe to request that migration.
    ///
    /// It is deliberately a LITERAL pin. A future bump is supposed to make this line fail, because that
    /// failure is the prompt to answer CLAUDE.md's "Analysis migration required: yes/no" for whatever
    /// the bump carries — the question this file exists to stop anyone skipping.
    func testRecipeVersionIsTwentyAndOlderInstallsMigrateToIt() {
        XCTAssertEqual(IntelligenceEngine.currentAnalysisRecipeVersion, 20,
                       "recipe version changed — answer 'Analysis migration required' for what moved")
        for stored in [8, 11, 12, 13, 14, 15, 16, 17, 18, 19] {
            XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: stored),
                           .migrate(from: stored, to: 20))
        }
    }

    /// AI-20 moves the stored Charge (an optional baseline that is not yet usable is left out), so every
    /// install below it re-scores the standard window, an AI-19 one included, and an AI-20 one none. It
    /// touches no workout row and no ledger.
    func testAI20RescoresTheStandardWindow() {
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 19), 21)
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 20), 0)
        XCTAssertFalse(IntelligenceEngine.migrationRefillsCardioLedger(from: 19, to: 20))
        XCTAssertFalse(IntelligenceEngine.migrationCorrectsWorkoutEnergy(from: 19, to: 20))
        XCTAssertFalse(IntelligenceEngine.migrationFillsWorkoutHeartRate(from: 19, to: 20))
    }

    /// AI-18 moves the stored Charge (windowed baselines, the import only seeding, #2525), so every install
    /// below it re-scores the standard window, an AI-17 one included. (An AI-18 install still owes AI-20's
    /// re-score, pinned above.) It touches no workout row and no ledger.
    func testAI18RescoresTheStandardWindow() {
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 17), 21)
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 18), 21)
        XCTAssertFalse(IntelligenceEngine.migrationRefillsCardioLedger(from: 17, to: 18))
        XCTAssertFalse(IntelligenceEngine.migrationCorrectsWorkoutEnergy(from: 17, to: 18))
        XCTAssertFalse(IntelligenceEngine.migrationFillsWorkoutHeartRate(from: 17, to: 18))
    }

    /// AI-17 moves stored daily rows (deep prior, 500 ms fill, off-wrist tails, resting HR), so every
    /// install below it re-scores the standard window, an AI-16 one included, and an AI-17 one none.
    func testAI17RescoresTheStandardWindow() {
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 16), 21)
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 13), 21)
        XCTAssertFalse(IntelligenceEngine.migrationRefillsCardioLedger(from: 16, to: 17))
        XCTAssertFalse(IntelligenceEngine.migrationCorrectsWorkoutEnergy(from: 16, to: 17))
        XCTAssertFalse(IntelligenceEngine.migrationFillsWorkoutHeartRate(from: 16, to: 17))
    }

    /// AI-15 corrects stored session energy and no daily row: an AI-13 or AI-14 install runs the
    /// correction again, and so does every older install crossing it. (Their daily re-score now comes
    /// from AI-17, pinned above.)
    func testAI15CorrectsSessionEnergy() {
        XCTAssertTrue(IntelligenceEngine.migrationCorrectsWorkoutEnergy(from: 12, to: 15))
        XCTAssertTrue(IntelligenceEngine.migrationCorrectsWorkoutEnergy(from: 8, to: 15))
        XCTAssertTrue(IntelligenceEngine.migrationCorrectsWorkoutEnergy(from: 13, to: 15))
        XCTAssertTrue(IntelligenceEngine.migrationCorrectsWorkoutEnergy(from: 14, to: 15))
        XCTAssertFalse(IntelligenceEngine.migrationCorrectsWorkoutEnergy(from: 15, to: 15))
    }

    /// AI-16 fills Apple Health workouts' heart rate; an AI-15 install runs the fill and not the energy
    /// correction again.
    func testAI16FillsWorkoutHeartRateWithoutRecorrectingEnergy() {
        XCTAssertTrue(IntelligenceEngine.migrationFillsWorkoutHeartRate(from: 15, to: 16))
        XCTAssertTrue(IntelligenceEngine.migrationFillsWorkoutHeartRate(from: 8, to: 16))
        XCTAssertFalse(IntelligenceEngine.migrationFillsWorkoutHeartRate(from: 16, to: 16))
        XCTAssertFalse(IntelligenceEngine.migrationCorrectsWorkoutEnergy(from: 15, to: 16))
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

    /// AI-10, AI-11 and AI-12 change daily rows, so every install below AI-12 re-scores at least the
    /// standard window, an AI-9, AI-10 or AI-11 one included. Only crossing AI-9 refills the cardio ledger.
    func testAI10ToAI12RescoreTheStandardWindowWithoutRefillingTheLedger() {
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 9), 21)
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 10), 21)
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 11), 21)
        XCTAssertFalse(IntelligenceEngine.migrationRefillsCardioLedger(from: 9, to: 12))
        XCTAssertFalse(IntelligenceEngine.migrationRefillsCardioLedger(from: 11, to: 12))
    }

    /// AI-11 must reach every day a build could have scored with #2358's mean: back to 2026-09-02, never
    /// fewer than the standard 21 days and never more than 45. Nothing once AI-11 is applied.
    func testAI11ReachesBackToTheFirstPossibleMeanDay() {
        XCTAssertEqual(IntelligenceEngine.restingHRRepairDays(from: 10, today: "2026-09-28"), 27)
        XCTAssertEqual(IntelligenceEngine.restingHRRepairDays(from: 9, today: "2026-09-28"), 27)
        XCTAssertEqual(IntelligenceEngine.restingHRRepairDays(from: 10, today: "2026-09-10"), 21)
        XCTAssertEqual(IntelligenceEngine.restingHRRepairDays(from: 10, today: "2026-12-31"), 45)
        XCTAssertEqual(IntelligenceEngine.restingHRRepairDays(from: 11, today: "2026-09-28"), 0)
    }

    /// AI-9 changes the stored cardio loads and no daily row. An install owing it still re-scores the
    /// standard window now, because AI-10 is owed too; every migration that crosses AI-9 refills the ledger.
    func testAI9RefillsTheLedger() {
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 8), 21)
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 7), 21)
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 0), 21)
        XCTAssertTrue(IntelligenceEngine.migrationRefillsCardioLedger(from: 8, to: 9))
        XCTAssertTrue(IntelligenceEngine.migrationRefillsCardioLedger(from: 0, to: 9))
        XCTAssertFalse(IntelligenceEngine.migrationRefillsCardioLedger(from: 9, to: 10))
        XCTAssertFalse(IntelligenceEngine.migrationRefillsCardioLedger(from: 6, to: 8))
    }

    /// The recipe is about the MEANING of stored scores, not about the app's identity. An Xcode install
    /// or a UI-only release must never launch a historical rescore, which is what reading a marketing or
    /// build number here would cause. Pinned because the mistake is invisible until someone's phone
    /// spends twenty minutes re-scoring after a cosmetic update.
    func testAnInstallAlreadyAtTheCurrentRecipeNeverRescoresOnRelaunch() {
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 20), .upToDate)
        // And a database written by a NEWER build that was rolled back stays put rather than
        // "migrating" backwards into a rescore that would overwrite better values with worse ones.
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 21), .upToDate)
    }

    // MARK: - The fork's own recipe lineage

    /// ryanbr/noop has no analysis recipe. The fork's lineage is stored under its own namespace and
    /// named "AI-n", so an upstream counter added later under a plain name cannot pass for one of ours.
    func testTheRecipeLivesUnderTheForkNamespace() {
        XCTAssertEqual(IntelligenceEngine.analysisRecipeCursor, "noopai:analysisRecipeVersion")
        XCTAssertNotEqual(IntelligenceEngine.analysisRecipeCursor, IntelligenceEngine.legacyAnalysisRecipeCursor)
        XCTAssertEqual(IntelligenceEngine.recipeLabel(8), "AI-8")
    }

    /// Only values this fork could have written under the legacy name are adopted.
    func testOnlyTheForksLegacyValuesAreAdopted() {
        XCTAssertNil(IntelligenceEngine.adoptableLegacyRecipe(nil))
        XCTAssertNil(IntelligenceEngine.adoptableLegacyRecipe(0))
        XCTAssertEqual(IntelligenceEngine.adoptableLegacyRecipe(1), 1)
        XCTAssertEqual(IntelligenceEngine.adoptableLegacyRecipe(8), 8)
        XCTAssertNil(IntelligenceEngine.adoptableLegacyRecipe(9),
                     "the fork never wrote 9 under the legacy name; such a value is someone else's")
    }

    /// An install from before the rename keeps its place: its legacy AI-8 is adopted, so it owes only
    /// AI-9 — the ledger refill — and no daily re-score from 0.
    func testAPreRenameInstallAdoptsItsRecipe() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("recipe-rename-\(UUID().uuidString).sqlite").path
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let store = try await WhoopStore(path: path)
        try await store.setCursor(IntelligenceEngine.legacyAnalysisRecipeCursor, 8)
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "my-whoop")
        let ok = await engine.prepareAnalysisRecipe()
        XCTAssertTrue(ok)
        let migrated = try await store.cursor(IntelligenceEngine.analysisRecipeCursor)
        XCTAssertEqual(migrated, IntelligenceEngine.currentAnalysisRecipeVersion)
        let legacy = try await store.cursor(IntelligenceEngine.legacyAnalysisRecipeCursor)
        XCTAssertEqual(legacy, 8, "the legacy cursor is read, never written")
    }

    // MARK: - A store switched over from upstream NOOP

    /// Upstream 11.6/11.7 persisted nights with sleep but no HRV or Charge. Such a store has no cursor,
    /// and anchoring it like a pre-coordinator install would freeze those blanks.
    func testAStoreFromUpstreamMigratesInsteadOfAnchoring() {
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: nil, openedFromUpstream: true),
                       .migrate(from: 0, to: IntelligenceEngine.currentAnalysisRecipeVersion))
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: nil, openedFromUpstream: false),
                       .anchorCurrent)
        // Once the fork has written its cursor, upstream origin no longer matters.
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(
            storedVersion: IntelligenceEngine.currentAnalysisRecipeVersion, openedFromUpstream: true), .upToDate)
    }

    func testTheUpstreamRepairWindowReachesTheEarliestBlankedNightWithinBounds() {
        XCTAssertEqual(IntelligenceEngine.upstreamRepairWindowDays(earliestMissingDay: nil, today: "2026-09-17"), 21)
        XCTAssertEqual(IntelligenceEngine.upstreamRepairWindowDays(earliestMissingDay: "2026-09-10", today: "2026-09-17"), 21)
        XCTAssertEqual(IntelligenceEngine.upstreamRepairWindowDays(earliestMissingDay: "2026-08-21", today: "2026-09-17"), 28)
        XCTAssertEqual(IntelligenceEngine.upstreamRepairWindowDays(earliestMissingDay: "2026-08-21", today: "2026-12-01"), 45)
        // Across a DST change (Europe, 2026-10-25) the span counts calendar days.
        XCTAssertEqual(IntelligenceEngine.upstreamRepairWindowDays(earliestMissingDay: "2026-10-01", today: "2026-10-31"), 31)
    }
}
