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
    /// witnessing one. This one names the numbers: an install carrying the v7 R-R precedence recipe must
    /// ask for the v8 Lab Book key migration, and it must ask for it as `7 → 8` rather than another pair.
    ///
    /// It is deliberately a LITERAL pin. A future bump is supposed to make this line fail, because that
    /// failure is the prompt to answer CLAUDE.md's "Analysis migration required: yes/no" for whatever
    /// the bump carries — the question this file exists to stop anyone skipping.
    func testRecipeVersionIsEightAndAV7InstallMigratesToIt() {
        XCTAssertEqual(IntelligenceEngine.currentAnalysisRecipeVersion, 8,
                       "recipe version changed — answer 'Analysis migration required' for what moved")
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 7),
                       .migrate(from: 7, to: 8))
    }

    /// The recipe is about the MEANING of stored scores, not about the app's identity. An Xcode install
    /// or a UI-only release must never launch a historical rescore, which is what reading a marketing or
    /// build number here would cause. Pinned because the mistake is invisible until someone's phone
    /// spends twenty minutes re-scoring after a cosmetic update.
    func testAnInstallAlreadyAtTheCurrentRecipeNeverRescoresOnRelaunch() {
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 8), .upToDate)
        // And a database written by a NEWER build that was rolled back stays put rather than
        // "migrating" backwards into a rescore that would overwrite better values with worse ones.
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 9), .upToDate)
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

    /// An install from before the rename keeps its place: the legacy value moves to the new cursor and
    /// nothing is re-scored for the rename itself.
    func testAPreRenameInstallAdoptsItsRecipeWithoutRescoring() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("recipe-rename-\(UUID().uuidString).sqlite").path
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let store = try await WhoopStore(path: path)
        let current = IntelligenceEngine.currentAnalysisRecipeVersion
        try await store.setCursor(IntelligenceEngine.legacyAnalysisRecipeCursor, current)
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "my-whoop")
        let ok = await engine.prepareAnalysisRecipe()
        XCTAssertTrue(ok)
        let adopted = try await store.cursor(IntelligenceEngine.analysisRecipeCursor)
        XCTAssertEqual(adopted, current)
        XCTAssertEqual(engine.analysisMaintenancePhase, .idle, "the rename alone must not start a reanalysis")
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
