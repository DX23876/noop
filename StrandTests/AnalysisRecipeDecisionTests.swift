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
}
