import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// The Training Load cardio lane maps its Banister TRIMP onto Effort's axis against Banister's own daily
/// ceiling (`banisterLaneEffort`). Daily Effort itself has its own curve since #2438 step 1.
final class StrainBanisterDenominatorTests: XCTestCase {

    private let d = 1e-9

    // MARK: - The derivation

    /// Ceiling = 24 h × ΔHRR 1.0 × 0.64 × e^b, stated independently of the implementation.
    func testTheDailyCeilingIsTwentyFourHoursAtFullReserve() {
        XCTAssertEqual(StrainScorer.banisterDailyCeiling(b: StrainScorer.banisterBMen),
                       1440.0 * 0.64 * exp(1.92), accuracy: d)
        XCTAssertEqual(StrainScorer.banisterDailyCeiling(b: StrainScorer.banisterBWomen),
                       1440.0 * 0.64 * exp(1.67), accuracy: d)
    }
}
