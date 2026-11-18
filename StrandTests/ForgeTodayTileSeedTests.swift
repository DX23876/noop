import XCTest
@testable import Strand

/// Carrying an existing Today into the new design (owner, 2026-11-18). The twin of Android's
/// `TodayWidgetsTest.firstTiles…` cases.
///
/// The promise being tested is "nothing gets rearranged": whoever arranged their Key Metrics finds the
/// same metrics in the same order as tiles, and whoever never touched them finds the set Today has always
/// placed.
final class ForgeTodayTileSeedTests: XCTestCase {

    func testNoSavedLayoutKeepsTheFixedFirstSet() {
        XCTAssertEqual(ForgeTodayTileSeed.measureKeys(selection: nil), ForgeTodayTileSeed.firstSet)
        XCTAssertEqual(ForgeTodayTileSeed.measureKeys(selection: "  "), ForgeTodayTileSeed.firstSet)
    }

    func testASavedLayoutIsCarriedInItsOwnOrder() {
        XCTAssertEqual(ForgeTodayTileSeed.measureKeys(selection: "weight,hrv,steps"),
                       ["weight", "hrv", "steps"])
    }

    /// The three rings directly above already say today's number, and these exist as tiles only across the
    /// whole row. Carrying them would turn a small tile into a full row that nobody asked for.
    func testChargeEffortAndRestAreNotCarried() {
        XCTAssertEqual(ForgeTodayTileSeed.measureKeys(selection: "charge,effort,rest,hrv"), ["hrv"])
    }

    /// The stored spelling is the Key-Metric rawValue; the tiles are keyed by the measure catalogue.
    func testTheStoredNamesAreTranslatedToMeasureKeys() {
        XCTAssertEqual(ForgeTodayTileSeed.measureKeys(selection: "restingHr,bloodOxygen,respiratory,skinTemp,calories"),
                       ["rhr", "spo2", "resp_rate", "skin_temp", "active_kcal"])
    }

    /// Every metric that can be in a stored layout must say where it goes, or a future tile is lost in
    /// silence rather than reported. A metric is either carried as an ordinary tile or drawn across the
    /// whole row, never both and never neither — which is what keeps the two lists from drifting apart.
    func testEveryMetricEitherCarriesOrIsAWholeRowTile() {
        for metric in KeyMetric.allCases {
            let carried = metric.measureKey != nil
            let wholeRow = metric.wholeRowMeasureKey != nil
            XCTAssertNotEqual(carried, wholeRow, "\(metric.rawValue) must be exactly one of the two")
        }
    }

    func testTheWholeRowSetIsTheThreeTheRingsAlreadyShow() {
        XCTAssertEqual(ForgeTodayTileSeed.wholeRowMeasures, ["recovery", "strain", "sleep_performance"])
        for metric in [KeyMetric.charge, .effort, .rest] {
            XCTAssertNil(metric.measureKey, "\(metric.rawValue) must not be carried into a small tile")
        }
    }
}
