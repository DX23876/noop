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
    /// witnessing one. This one names AI-32 (the maximum heart rate of #2438 step 0) and requires every
    /// older stored recipe, AI-31 included, to request that migration.
    ///
    /// It is deliberately a LITERAL pin. A future bump is supposed to make this line fail, because that
    /// failure is the prompt to answer "Analysis migration required: yes/no" for whatever the bump carries.
    func testRecipeVersionIsThirtyTwoAndOlderInstallsMigrateToIt() {
        XCTAssertEqual(AnalysisRecipe.currentVersion, 32,
                       "recipe version changed — answer 'Analysis migration required' for what moved")
        for stored in [0, 8, 11, 15, 19, 20, 28, 29, 30, 31] {
            XCTAssertEqual(AnalysisRecipe.decision(storedVersion: stored),
                           .migrate(from: stored, to: 32))
        }
    }

    // MARK: - The one rule (D19)

    /// Every bump runs the same steps in the same order; the legacy input repairs come first because the
    /// rebuild reads what they fix, and the screens refresh last, right before the recipe cursor moves.
    func testEveryBumpRunsTheSameRebuildInOrder() {
        XCTAssertEqual(AnalysisRecipe.RebuildStep.allCases,
                       [.legacyRepairs, .healthspanReset, .workoutPeaks, .dailyHistory, .weeklyScores, .stressProxy,
                        .rhythmDays, .workoutHeartRate, .cardioLoad, .energyHistory, .publish])
    }

    /// An interrupted rebuild resumes at the step it was in, and only for the recipe it was working toward.
    func testAnInterruptedRebuildResumesAtTheOwedStep() {
        XCTAssertEqual(AnalysisRecipe.firstOwedStep(target: 31, storedPosition: nil), .legacyRepairs)
        let afterDaily = AnalysisRecipe.rebuildPosition(target: 31, after: .dailyHistory)
        XCTAssertEqual(AnalysisRecipe.firstOwedStep(target: 31, storedPosition: afterDaily), .weeklyScores)
        // A position left by an older bump that never finished starts the newer rebuild from the beginning.
        XCTAssertEqual(AnalysisRecipe.firstOwedStep(target: 32, storedPosition: afterDaily), .legacyRepairs)
        // A finished AI-31 rebuild (the testing build of 2026-10-26) owes the whole AI-32 rebuild.
        let finished31 = AnalysisRecipe.rebuildPosition(target: 31, after: .publish)
        XCTAssertEqual(AnalysisRecipe.firstOwedStep(target: 32, storedPosition: finished31), .legacyRepairs)
        let afterCardio = AnalysisRecipe.rebuildPosition(target: 31, after: .cardioLoad)
        XCTAssertEqual(AnalysisRecipe.firstOwedStep(target: 31, storedPosition: afterCardio), .energyHistory)
    }

    /// A rebuild stopped after its last step but before the recipe cursor moved owes no step: the position
    /// after `.publish` used to read as no position at all and start the whole rebuild again.
    func testARebuildPastItsLastStepOwesNoStep() {
        let finished = AnalysisRecipe.rebuildPosition(target: 32, after: .publish)
        XCTAssertNil(AnalysisRecipe.firstOwedStep(target: 32, storedPosition: finished))
        let afterEnergy = AnalysisRecipe.rebuildPosition(target: 32, after: .energyHistory)
        XCTAssertEqual(AnalysisRecipe.firstOwedStep(target: 32, storedPosition: afterEnergy), .publish)
    }

    /// The repairs of stored inputs that older recipes shipped still run for a store that predates them;
    /// everything the other old recipes derived is part of the rebuild.
    func testOnlyStoresThatPredateTheInputRepairsOweThem() {
        XCTAssertEqual(AnalysisRecipe.legacyRepairs(from: 0), [.workoutEnergy, .healthProjections])
        XCTAssertEqual(AnalysisRecipe.legacyRepairs(from: 14), [.workoutEnergy, .healthProjections])
        XCTAssertEqual(AnalysisRecipe.legacyRepairs(from: 15), [.healthProjections])
        XCTAssertEqual(AnalysisRecipe.legacyRepairs(from: 19), [])
        XCTAssertEqual(AnalysisRecipe.legacyRepairs(from: 30), [])
    }

    /// The daily step reaches the oldest day with raw strap data, never fewer than the standard window.
    func testTheDailyStepCoversEveryDayWithRawData() {
        XCTAssertEqual(AnalysisRecipe.rebuildDays(earliestRawDay: nil, today: "2026-10-25"), 21)
        XCTAssertEqual(AnalysisRecipe.rebuildDays(earliestRawDay: "2026-10-20", today: "2026-10-25"), 21)
        XCTAssertEqual(AnalysisRecipe.rebuildDays(earliestRawDay: "2026-07-13", today: "2026-10-24"), 104)
        XCTAssertEqual(AnalysisRecipe.rebuildDays(earliestRawDay: "2025-10-25", today: "2026-10-25"), 366)
        // Across a DST change (Europe, 2026-10-25) the span counts calendar days.
        XCTAssertEqual(AnalysisRecipe.rebuildDays(earliestRawDay: "2026-10-01", today: "2026-10-31"), 31)
    }

    /// The recipe is about the MEANING of stored scores, not about the app's identity. An Xcode install
    /// or a UI-only release must never launch a historical rescore, which is what reading a marketing or
    /// build number here would cause. Pinned because the mistake is invisible until someone's phone
    /// spends twenty minutes re-scoring after a cosmetic update.
    func testAnInstallAlreadyAtTheCurrentRecipeNeverRescoresOnRelaunch() {
        XCTAssertEqual(AnalysisRecipe.decision(storedVersion: AnalysisRecipe.currentVersion), .upToDate)
        // And a database written by a NEWER build that was rolled back stays put rather than
        // "migrating" backwards into a rescore that would overwrite better values with worse ones.
        XCTAssertEqual(AnalysisRecipe.decision(storedVersion: AnalysisRecipe.currentVersion + 1), .upToDate)
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
}
