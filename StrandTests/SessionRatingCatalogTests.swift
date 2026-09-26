import XCTest
import StrandAnalytics
@testable import Strand

/// Guards the catalog against the rating policy drifting out of step with it: a sport added to
/// `WorkoutCatalog` that the policy cannot place would be asked about after every session, silently.
final class SessionRatingCatalogTests: XCTestCase {
    func testEveryCatalogSportExceptOtherHasAFamily() {
        let unplaced = WorkoutCatalog.all.map(\.name).filter {
            SessionRatingPolicy.family(forSport: $0) == .unknown
        }
        XCTAssertEqual(unplaced, ["Other"])
    }
}
