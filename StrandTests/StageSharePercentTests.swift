import XCTest
import StrandAnalytics
import StrandDesign
@testable import Strand

/// One apportionment for a night's stage shares (Refs ryanbr/noop#2927).
///
/// The stage breakdown apportions the four shares with largest remainder so they sum to 100, while
/// "Stages vs typical" beside it rounded each share on its own: the same stage of the same night could
/// read 54 % in one card and 53 % in the next. Both now read `Stages.sharePercent`, and the Android lanes
/// read the Kotlin twin of the same helper over the same input order.
///
/// Pure: builds `Stages` values directly, no store and no view mounting.
final class StageSharePercentTests: XCTestCase {
    /// A night whose exact shares are 6.0 / 50.0 / 18.57 / 25.48 %: rounding each on its own gives
    /// 6 + 50 + 19 + 25 = 100 here, but the deep/REM pair is where the two methods part on other nights.
    private let night = Stages(awake: 25, light: 210, deep: 78, rem: 107)

    func testTheFourSharesComeFromOneApportionmentAndSumTo100() {
        let shares = [night.sharePercent(.awake), night.sharePercent(.light),
                      night.sharePercent(.deep), night.sharePercent(.rem)]
        XCTAssertEqual(shares, StagePercentages.wholePercentages([25, 210, 78, 107]))
        XCTAssertEqual(shares.reduce(0, +), 100)
    }

    /// The night that shows the difference: three equal stages and a short fourth. Largest remainder
    /// gives 30/29/29/12, where rounding each share alone gives 29/29/29/12 and loses a point.
    func testWhereRoundingEachShareOnItsOwnDisagrees() {
        let s = Stages(awake: 5, light: 5, deep: 5, rem: 2)
        XCTAssertEqual([s.sharePercent(.awake), s.sharePercent(.light),
                        s.sharePercent(.deep), s.sharePercent(.rem)], [30, 29, 29, 12])
        let alone = [5.0, 5.0, 5.0, 2.0].map { Int(($0 / 17 * 100).rounded()) }
        XCTAssertEqual(alone, [29, 29, 29, 12])
        XCTAssertEqual(alone.reduce(0, +), 99, "which is what the second card used to print")
    }

    func testANightWithNoStagesHasNoShares() {
        let empty = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        for stage in [SleepStage.awake, .light, .deep, .rem] {
            XCTAssertEqual(empty.sharePercent(stage), 0)
        }
    }
}
