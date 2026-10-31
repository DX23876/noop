import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// The Training Load cardio lane maps its Banister TRIMP onto Effort's axis against Banister's own daily
/// ceiling (`banisterLaneEffort`). Daily Effort itself has its own curve since #2438 step 1.
final class StrainBanisterDenominatorTests: XCTestCase {

    private let d = 1e-9

    // MARK: - The derivation

    /// Ceiling = 24 h × ΔHRR 1.0 × scale × e^b, stated independently of the implementation, with the
    /// PUBLISHED pair per sex: 0.64 and 1.92 for men, 0.86 and 1.67 for women (upstream #2835), and the
    /// fork's mean pair 0.75 and 1.795 for a profile without a sex. The women's line used to read
    /// `1440 × 0.64 × e^1.67`, the men's multiplier against the women's exponent, which is what the lane did.
    func testTheDailyCeilingIsTwentyFourHoursAtFullReserve() {
        XCTAssertEqual(StrainScorer.banisterDailyCeiling(StrainScorer.banisterCoefficients(sex: "male")),
                       1440.0 * 0.64 * exp(1.92), accuracy: d)
        XCTAssertEqual(StrainScorer.banisterDailyCeiling(StrainScorer.banisterCoefficients(sex: "female")),
                       1440.0 * 0.86 * exp(1.67), accuracy: d)
        XCTAssertEqual(StrainScorer.banisterDailyCeiling(StrainScorer.banisterCoefficients(sex: "")),
                       1440.0 * 0.75 * exp(1.795), accuracy: d)
    }

    /// Selecting a sex yields BOTH of its coefficients, so half of a pair cannot be selected.
    func testEachSexGetsBothOfItsCoefficients() {
        XCTAssertEqual(StrainScorer.banisterCoefficients(sex: "male"),
                       StrainScorer.BanisterCoefficients(scale: 0.64, b: 1.92))
        XCTAssertEqual(StrainScorer.banisterCoefficients(sex: " Female "),
                       StrainScorer.BanisterCoefficients(scale: 0.86, b: 1.67))
        XCTAssertEqual(StrainScorer.banisterCoefficients(sex: "nonbinary"),
                       StrainScorer.BanisterCoefficients(scale: 0.75, b: 1.795))
        XCTAssertEqual(StrainScorer.banisterCoefficients(sex: ""),
                       StrainScorer.BanisterCoefficients(scale: 0.75, b: 1.795))
    }

    /// The lane Effort of an hour at ΔHRR 0.5 on each axis, worked independently: men 50.1446 TRIMP over a
    /// 6,286 ceiling, women 59.4642 over 6,579. The women's figure was 48.28 with the men's multiplier.
    func testLaneEffortPinsBothPublishedPairs() {
        XCTAssertEqual(StrainScorer.banisterLaneEffort(50.14457228972386, sex: "male"), 44.99, accuracy: d)
        XCTAssertEqual(StrainScorer.banisterLaneEffort(59.46420244580492, sex: "female"), 46.66, accuracy: d)
    }
}
