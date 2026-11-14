import XCTest
@testable import StrandAnalytics

/// Which of the four things a cardio-load card says, decided once for both platforms.
final class CardioLoadReadoutTests: XCTestCase {

    private func resolve(possible: Int = 8, measured: Int = 7, seriesMeasured: Bool = true,
                         percent: Double? = nil, band: RelativeLoadBand? = nil,
                         weeks: Int = 0) -> CardioLoadReadout? {
        CardioLoadReadout.resolve(possibleCount: possible, measuredCount: measured,
                                  seriesMeasured: seriesMeasured, percentChange: percent,
                                  band: band, completeWeeks: weeks)
    }

    func testNoCardioAtAllSaysNothing() {
        XCTAssertNil(resolve(possible: 0, measured: 0))
    }

    func testWithoutAnyHeartRateThereIsNothingToCompare() {
        XCTAssertEqual(resolve(seriesMeasured: false, percent: 18, weeks: 12), .noHeartRate)
    }

    func testAComparisonWinsWhereverThereIsOne() {
        XCTAssertEqual(resolve(percent: 18, band: .higher, weeks: 2),
                       .comparison(percent: 18, band: .higher, readsLow: false))
    }

    /// Half the sessions or fewer carrying heart rate is the point at which the comparison understates
    /// the week, and the card has to say so.
    func testAThinWeekMarksTheComparisonAsReadingLow() {
        guard case .comparison(_, _, let readsLow) = resolve(possible: 8, measured: 3, percent: 5) else {
            return XCTFail("expected a comparison")
        }
        XCTAssertTrue(readsLow)
        guard case .comparison(_, _, let enough) = resolve(possible: 8, measured: 5, percent: 5) else {
            return XCTFail("expected a comparison")
        }
        XCTAssertFalse(enough)
    }

    func testWithoutAComparisonTheCauseIsNamed() {
        XCTAssertEqual(resolve(weeks: 7), .notEnoughWeeks)
        XCTAssertEqual(resolve(possible: 8, measured: 2, weeks: 8),
                       .tooFewMeasured(measured: 2, possible: 8))
    }

    /// The names cross to Kotlin, so they are part of the contract rather than a detail.
    func testTheKindNamesAreStable() {
        XCTAssertEqual(CardioLoadReadout.noHeartRate.kind, "noHeartRate")
        XCTAssertEqual(CardioLoadReadout.notEnoughWeeks.kind, "notEnoughWeeks")
        XCTAssertEqual(CardioLoadReadout.tooFewMeasured(measured: 1, possible: 2).kind, "tooFewMeasured")
        XCTAssertEqual(CardioLoadReadout.comparison(percent: 1, band: nil, readsLow: false).kind, "comparison")
    }
}
