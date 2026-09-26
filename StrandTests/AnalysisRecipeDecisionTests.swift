import XCTest
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
    /// witnessing one. This one names the numbers: an install carrying AI-9 (the Banister cardio ledger)
    /// must ask for AI-10 (the 2026-09-26 upstream scoring changes), and it must ask for it as `9 → 10`.
    ///
    /// It is deliberately a LITERAL pin. A future bump is supposed to make this line fail, because that
    /// failure is the prompt to answer CLAUDE.md's "Analysis migration required: yes/no" for whatever
    /// the bump carries — the question this file exists to stop anyone skipping.
    func testRecipeVersionIsTenAndAnAI9InstallMigratesToIt() {
        XCTAssertEqual(IntelligenceEngine.currentAnalysisRecipeVersion, 10,
                       "recipe version changed — answer 'Analysis migration required' for what moved")
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 9),
                       .migrate(from: 9, to: 10))
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 8),
                       .migrate(from: 8, to: 10))
    }

    /// AI-10 changes daily rows, so every install below it re-scores the standard window, an AI-9 one
    /// included. Only crossing AI-9 refills the cardio ledger; AI-9 → AI-10 does not.
    func testAI10RescoresTheStandardWindowWithoutRefillingTheLedger() {
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 9), 21)
        XCTAssertEqual(IntelligenceEngine.migrationDailyDays(from: 10), 0)
        XCTAssertFalse(IntelligenceEngine.migrationRefillsCardioLedger(from: 9, to: 10))
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
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 10), .upToDate)
        // And a database written by a NEWER build that was rolled back stays put rather than
        // "migrating" backwards into a rescore that would overwrite better values with worse ones.
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 11), .upToDate)
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
