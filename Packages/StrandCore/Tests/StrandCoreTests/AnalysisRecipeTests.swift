import XCTest
import StrandCore

final class AnalysisRecipeTests: XCTestCase {
    func testExistingInstallWithoutCursorAnchorsWithoutReanalysis() {
        XCTAssertEqual(AnalysisRecipe.decision(storedVersion: nil), .anchorCurrent)
    }

    func testCurrentAndFutureRecipesDoNotReanalyze() {
        let current = AnalysisRecipe.currentVersion
        XCTAssertEqual(AnalysisRecipe.decision(storedVersion: current), .upToDate)
        XCTAssertEqual(AnalysisRecipe.decision(storedVersion: current + 1), .upToDate)
    }

    func testOlderRecipeRequestsExplicitMigration() {
        let current = AnalysisRecipe.currentVersion
        XCTAssertEqual(
            AnalysisRecipe.decision(storedVersion: current - 1),
            .migrate(from: current - 1, to: current))
    }

    /// The tests above are written against `current`, so they stay green through a bump without ever
    /// witnessing one. This one names AI-19, the Apple Health projection/provenance repair, and
    /// requires every older stored recipe to request that migration.
    ///
    /// It is deliberately a LITERAL pin. A future bump is supposed to make this line fail, because that
    /// failure is the prompt to answer CLAUDE.md's "Analysis migration required: yes/no" for whatever
    /// the bump carries — the question this file exists to stop anyone skipping.
    func testRecipeVersionIsThirtyAndOlderInstallsMigrateToIt() {
        XCTAssertEqual(AnalysisRecipe.currentVersion, 30,
                       "recipe version changed — answer 'Analysis migration required' for what moved")
        for stored in [8, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29] {
            XCTAssertEqual(AnalysisRecipe.decision(storedVersion: stored),
                           .migrate(from: stored, to: 30))
        }
    }

    /// AI-30 reads Apple Health's body fat and lean mass: it rebuilds the AgeLess weeks and prices the energy
    /// window again (for Katch–McArdle only, decided at run time), and touches nothing else.
    func testAI30RebuildsAgeLessAndRepricesBodyFatEnergy() {
        XCTAssertTrue(AnalysisRecipe.migrationReadsAppleBody(from: 29, to: 30))
        XCTAssertFalse(AnalysisRecipe.migrationReadsAppleBody(from: 30, to: 30))
        XCTAssertTrue(AnalysisRecipe.migrationReadsAppleBody(from: 27, to: 30))
        XCTAssertTrue(AnalysisRecipe.migrationRebuildsHealthspan(from: 29, to: 30))
        XCTAssertFalse(AnalysisRecipe.migrationRebuildsHealthspan(from: 30, to: 30))
        XCTAssertFalse(AnalysisRecipe.migrationRepairsStressProxy(from: 29, to: 30))
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 29), 0)
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 29, to: 30))
        XCTAssertFalse(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 29, to: 30))
        XCTAssertFalse(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 29, to: 30))
    }

    /// AI-29 rebuilds the AgeLess weeks on the app's step resolver and nothing else; an install still owing
    /// AI-28 gets both, and the gap keys are cleared with the weeks.
    /// AI-28 repairs the stress proxy after a recalibration and nothing else.
    func testAI28RepairsOnlyTheStressProxy() {
        XCTAssertTrue(AnalysisRecipe.migrationRepairsStressProxy(from: 27, to: 28))
        XCTAssertFalse(AnalysisRecipe.migrationRepairsStressProxy(from: 28, to: 28))
        XCTAssertFalse(AnalysisRecipe.migrationRebuildsHealthspan(from: 27, to: 28))
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 27), 0)
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 27, to: 28))
        XCTAssertFalse(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 27, to: 28))
        XCTAssertFalse(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 27, to: 28))
    }

    /// AI-27 rebuilds the AgeLess weeks without the body-fat credit and nothing else.
    func testAI27RebuildsOnlyTheAgeLessWeeks() {
        XCTAssertTrue(AnalysisRecipe.migrationRebuildsHealthspan(from: 26, to: 27))
        XCTAssertFalse(AnalysisRecipe.migrationRebuildsHealthspan(from: 27, to: 27))
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 26), 0)
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 26, to: 27))
        XCTAssertFalse(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 26, to: 27))
        XCTAssertFalse(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 26, to: 27))
    }

    /// AI-26 rebuilds the AgeLess weeks on measured VO₂max only and nothing else.
    /// AI-25 rebuilds the AgeLess weeks on the climb-aware VO₂max and nothing else.
    func testAI25RebuildsOnlyTheAgeLessWeeks() {
        XCTAssertTrue(AnalysisRecipe.migrationRebuildsHealthspan(from: 24, to: 25))
        XCTAssertFalse(AnalysisRecipe.migrationRebuildsHealthspan(from: 27, to: 27))
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 24), 0)
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 24, to: 25))
        XCTAssertFalse(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 24, to: 25))
        XCTAssertFalse(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 24, to: 25))
    }

    /// AI-21 to AI-24 rebuild every AgeLess week and nothing else: no daily row, no ledger, no workout row.
    /// AI-20 moves the stored Charge (an optional baseline that is not yet usable is left out), so every
    /// install below it re-scores the standard window, an AI-19 one included, and an AI-20 one none. It
    /// touches no workout row and no ledger.
    func testAI20RescoresTheStandardWindow() {
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 19), 21)
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 20), 0)
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 19, to: 20))
        XCTAssertFalse(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 19, to: 20))
        XCTAssertFalse(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 19, to: 20))
    }

    /// AI-18 moves the stored Charge (windowed baselines, the import only seeding, #2525), so every install
    /// below it re-scores the standard window, an AI-17 one included. (An AI-18 install still owes AI-20's
    /// re-score, pinned above.) It touches no workout row and no ledger.
    func testAI18RescoresTheStandardWindow() {
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 17), 21)
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 18), 21)
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 17, to: 18))
        XCTAssertFalse(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 17, to: 18))
        XCTAssertFalse(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 17, to: 18))
    }

    /// AI-17 moves stored daily rows (deep prior, 500 ms fill, off-wrist tails, resting HR), so every
    /// install below it re-scores the standard window, an AI-16 one included, and an AI-17 one none.
    func testAI17RescoresTheStandardWindow() {
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 16), 21)
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 13), 21)
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 16, to: 17))
        XCTAssertFalse(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 16, to: 17))
        XCTAssertFalse(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 16, to: 17))
    }

    /// AI-15 corrects stored session energy and no daily row: an AI-13 or AI-14 install runs the
    /// correction again, and so does every older install crossing it. (Their daily re-score now comes
    /// from AI-17, pinned above.)
    func testAI15CorrectsSessionEnergy() {
        XCTAssertTrue(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 12, to: 15))
        XCTAssertTrue(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 8, to: 15))
        XCTAssertTrue(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 13, to: 15))
        XCTAssertTrue(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 14, to: 15))
        XCTAssertFalse(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 15, to: 15))
    }

    /// AI-16 fills Apple Health workouts' heart rate; an AI-15 install runs the fill and not the energy
    /// correction again.
    func testAI16FillsWorkoutHeartRateWithoutRecorrectingEnergy() {
        XCTAssertTrue(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 15, to: 16))
        XCTAssertTrue(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 8, to: 16))
        XCTAssertFalse(AnalysisRecipe.migrationFillsWorkoutHeartRate(from: 16, to: 16))
        XCTAssertFalse(AnalysisRecipe.migrationCorrectsWorkoutEnergy(from: 15, to: 16))
    }

    /// AI-10, AI-11 and AI-12 change daily rows, so every install below AI-12 re-scores at least the
    /// standard window, an AI-9, AI-10 or AI-11 one included. Only crossing AI-9 refills the cardio ledger.
    func testAI10ToAI12RescoreTheStandardWindowWithoutRefillingTheLedger() {
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 9), 21)
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 10), 21)
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 11), 21)
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 9, to: 12))
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 11, to: 12))
    }

    /// AI-11 must reach every day a build could have scored with #2358's mean: back to 2026-09-02, never
    /// fewer than the standard 21 days and never more than 45. Nothing once AI-11 is applied.
    func testAI11ReachesBackToTheFirstPossibleMeanDay() {
        XCTAssertEqual(AnalysisRecipe.restingHRRepairDays(from: 10, today: "2026-09-28"), 27)
        XCTAssertEqual(AnalysisRecipe.restingHRRepairDays(from: 9, today: "2026-09-28"), 27)
        XCTAssertEqual(AnalysisRecipe.restingHRRepairDays(from: 10, today: "2026-09-10"), 21)
        XCTAssertEqual(AnalysisRecipe.restingHRRepairDays(from: 10, today: "2026-12-31"), 45)
        XCTAssertEqual(AnalysisRecipe.restingHRRepairDays(from: 11, today: "2026-09-28"), 0)
    }

    /// AI-9 changes the stored cardio loads and no daily row. An install owing it still re-scores the
    /// standard window now, because AI-10 is owed too; every migration that crosses AI-9 refills the ledger.
    func testAI9RefillsTheLedger() {
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 8), 21)
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 7), 21)
        XCTAssertEqual(AnalysisRecipe.migrationDailyDays(from: 0), 21)
        XCTAssertTrue(AnalysisRecipe.migrationRefillsCardioLedger(from: 8, to: 9))
        XCTAssertTrue(AnalysisRecipe.migrationRefillsCardioLedger(from: 0, to: 9))
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 9, to: 10))
        XCTAssertFalse(AnalysisRecipe.migrationRefillsCardioLedger(from: 6, to: 8))
    }

    /// The recipe is about the MEANING of stored scores, not about the app's identity. An Xcode install
    /// or a UI-only release must never launch a historical rescore, which is what reading a marketing or
    /// build number here would cause. Pinned because the mistake is invisible until someone's phone
    /// spends twenty minutes re-scoring after a cosmetic update.
    func testAnInstallAlreadyAtTheCurrentRecipeNeverRescoresOnRelaunch() {
        XCTAssertEqual(AnalysisRecipe.decision(storedVersion: 30), .upToDate)
        // And a database written by a NEWER build that was rolled back stays put rather than
        // "migrating" backwards into a rescore that would overwrite better values with worse ones.
        XCTAssertEqual(AnalysisRecipe.decision(storedVersion: 31), .upToDate)
    }

    // MARK: - The fork's own recipe lineage

    /// ryanbr/noop has no analysis recipe. The fork's lineage is stored under its own namespace and
    /// named "AI-n", so an upstream counter added later under a plain name cannot pass for one of ours.
    func testTheRecipeLivesUnderTheForkNamespace() {
        XCTAssertEqual(AnalysisRecipe.cursor, "noopai:analysisRecipeVersion")
        XCTAssertNotEqual(AnalysisRecipe.cursor, AnalysisRecipe.legacyCursor)
        XCTAssertEqual(AnalysisRecipe.label(8), "AI-8")
    }

    /// Only values this fork could have written under the legacy name are adopted.
    func testOnlyTheForksLegacyValuesAreAdopted() {
        XCTAssertNil(AnalysisRecipe.adoptableLegacy(nil))
        XCTAssertNil(AnalysisRecipe.adoptableLegacy(0))
        XCTAssertEqual(AnalysisRecipe.adoptableLegacy(1), 1)
        XCTAssertEqual(AnalysisRecipe.adoptableLegacy(8), 8)
        XCTAssertNil(AnalysisRecipe.adoptableLegacy(9),
                     "the fork never wrote 9 under the legacy name; such a value is someone else's")
    }

    // MARK: - A store switched over from upstream NOOP

    /// Upstream 11.6/11.7 persisted nights with sleep but no HRV or Charge. Such a store has no cursor,
    /// and anchoring it like a pre-coordinator install would freeze those blanks.
    func testAStoreFromUpstreamMigratesInsteadOfAnchoring() {
        XCTAssertEqual(AnalysisRecipe.decision(storedVersion: nil, openedFromUpstream: true),
                       .migrate(from: 0, to: AnalysisRecipe.currentVersion))
        XCTAssertEqual(AnalysisRecipe.decision(storedVersion: nil, openedFromUpstream: false),
                       .anchorCurrent)
        // Once the fork has written its cursor, upstream origin no longer matters.
        XCTAssertEqual(AnalysisRecipe.decision(
            storedVersion: AnalysisRecipe.currentVersion, openedFromUpstream: true), .upToDate)
    }

    func testTheUpstreamRepairWindowReachesTheEarliestBlankedNightWithinBounds() {
        XCTAssertEqual(AnalysisRecipe.upstreamRepairWindowDays(earliestMissingDay: nil, today: "2026-09-17"), 21)
        XCTAssertEqual(AnalysisRecipe.upstreamRepairWindowDays(earliestMissingDay: "2026-09-10", today: "2026-09-17"), 21)
        XCTAssertEqual(AnalysisRecipe.upstreamRepairWindowDays(earliestMissingDay: "2026-08-21", today: "2026-09-17"), 28)
        XCTAssertEqual(AnalysisRecipe.upstreamRepairWindowDays(earliestMissingDay: "2026-08-21", today: "2026-12-01"), 45)
        // Across a DST change (Europe, 2026-10-25) the span counts calendar days.
        XCTAssertEqual(AnalysisRecipe.upstreamRepairWindowDays(earliestMissingDay: "2026-10-01", today: "2026-10-31"), 31)
    }
}
