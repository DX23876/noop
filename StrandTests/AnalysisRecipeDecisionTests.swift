import XCTest
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
    /// witnessing one. This one names the numbers: an install carrying the v6 native-training recipe must
    /// ask for the v7 R-R precedence migration, and it must ask for it as `6 → 7` rather than another pair.
    ///
    /// It is deliberately a LITERAL pin. A future bump is supposed to make this line fail, because that
    /// failure is the prompt to answer CLAUDE.md's "Analysis migration required: yes/no" for whatever
    /// the bump carries — the question this file exists to stop anyone skipping.
    func testRecipeVersionIsSevenAndAV6InstallMigratesToIt() {
        XCTAssertEqual(IntelligenceEngine.currentAnalysisRecipeVersion, 7,
                       "recipe version changed — answer 'Analysis migration required' for what moved")
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 6),
                       .migrate(from: 6, to: 7))
    }

    /// The recipe is about the MEANING of stored scores, not about the app's identity. An Xcode install
    /// or a UI-only release must never launch a historical rescore, which is what reading a marketing or
    /// build number here would cause. Pinned because the mistake is invisible until someone's phone
    /// spends twenty minutes re-scoring after a cosmetic update.
    func testAnInstallAlreadyAtTheCurrentRecipeNeverRescoresOnRelaunch() {
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 7), .upToDate)
        // And a database written by a NEWER build that was rolled back stays put rather than
        // "migrating" backwards into a rescore that would overwrite better values with worse ones.
        XCTAssertEqual(IntelligenceEngine.analysisRecipeDecision(storedVersion: 8), .upToDate)
    }
}
