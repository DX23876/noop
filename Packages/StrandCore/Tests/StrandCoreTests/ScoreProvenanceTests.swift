@testable import StrandCore
import XCTest

/// How the Today hero names the provider of a score, on both platforms (`ScoreProvenance.label`).
final class ScoreProvenanceTests: XCTestCase {
    func testAProviderIsNamedByItsStableIdOrItsBrand() {
        XCTAssertEqual(ScoreProvenance.label(sourceId: "apple-health", brand: nil), .name("Apple Watch"))
        XCTAssertEqual(ScoreProvenance.label(sourceId: "oura-api", brand: nil), .name("Oura"))
        XCTAssertEqual(ScoreProvenance.label(sourceId: "my-whoop", brand: nil), .name("WHOOP"))
        XCTAssertEqual(ScoreProvenance.label(sourceId: "whoop-AB12", brand: "whoop"), .name("WHOOP"),
                       "the registry brand wins, spelled as the product spells it")
        XCTAssertEqual(ScoreProvenance.label(sourceId: "polar-1", brand: "Polar"), .name("Polar"))
    }

    func testTheWordsEachPlatformTranslatesStayTokens() {
        XCTAssertEqual(ScoreProvenance.label(sourceId: "activity-file", brand: nil), .workoutFiles)
    }

    func testAnUnknownIdStaysVisibleRatherThanClaimingWhoop() {
        XCTAssertEqual(ScoreProvenance.label(sourceId: "something-new", brand: nil), .name("something-new"))
    }
}
