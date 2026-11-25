import XCTest
@testable import StrandAnalytics

/// The resting heart rate Effort is scored against (#2438, 2026-11-25): halfway between the night's lowest five
/// minutes and the main night's mean, as the curve was fitted on WHOOP's resting heart rate, which sits between
/// the two, and not on the lowest five minutes alone.
final class EffortRestingHRTests: XCTestCase {

    func testTheNightIsHalfwayBetweenItsLowestAndItsMean() {
        XCTAssertEqual(EffortRestingHR.nightValue(mean: 70, lowest: 58), 64)
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: 70, nightLowest: 58, recentNights: [80, 80],
                                               deviceProvided: 40), 64)
    }

    /// A mean below the lowest bin is impossible; the lowest stands. Either half missing leaves no night value.
    func testANightNeedsBothHalves() {
        XCTAssertEqual(EffortRestingHR.nightValue(mean: 55, lowest: 58), 58)
        XCTAssertNil(EffortRestingHR.nightValue(mean: nil, lowest: 58))
        XCTAssertNil(EffortRestingHR.nightValue(mean: 70, lowest: nil))
    }

    /// Without a night the median of the last seven nights' values stands in, the older ones ignored.
    func testWithoutANightTheLastSevenNightsStandIn() {
        let recent: [Double] = [90, 90, 90, 60, 62, 64, 66, 68, 70, 72]   // oldest first; the last seven: 66
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: nil, nightLowest: 50, recentNights: recent,
                                               deviceProvided: nil), 66)
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: nil, nightLowest: nil, recentNights: [60, 64],
                                               deviceProvided: nil), 62)
    }

    /// A device's own resting heart rate is a night's lowest reading, so it counts only with no heart-rate
    /// history at all; then the scorer's default.
    func testADevicesValueOnlyWithoutAnyNightAndThenTheDefault() {
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: nil, nightLowest: nil, recentNights: [],
                                               deviceProvided: 48), 48)
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: nil, nightLowest: nil, recentNights: [],
                                               deviceProvided: nil), StrainScorer.defaultRestingHR)
    }

    /// The nights before a day: the last seven with both halves, oldest first, skipping unworn days and a night
    /// with only one half, never the day itself and never one past the lookback.
    func testTheNightsBeforeADay() {
        var means: [String: Double] = ["2026-11-20": 99, "2026-11-19": 70, "2026-11-17": 69, "2026-11-16": 80,
                                       "2026-10-10": 50]
        var lowest: [String: Double] = ["2026-11-20": 99, "2026-11-19": 60, "2026-11-17": 59,
                                        "2026-10-10": 40]
        for d in 10 ... 15 { means["2026-11-\(d)"] = Double(d + 50); lowest["2026-11-\(d)"] = Double(d + 40) }
        XCTAssertEqual(EffortRestingHR.nightsBefore("2026-11-20", means: means, lowest: lowest),
                       [56, 57, 58, 59, 60, 64, 65])
        XCTAssertEqual(EffortRestingHR.nightsBefore("2026-11-01", means: ["2026-10-10": 50, "2026-09-01": 40],
                                                    lowest: ["2026-10-10": 40, "2026-09-01": 30]), [45])
    }

    /// A value no wearer can have is treated as missing, so one broken night cannot set a day's yardstick.
    func testImplausibleValuesAreMissing() {
        XCTAssertNil(EffortRestingHR.nightValue(mean: 0, lowest: 58))
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: .infinity, nightLowest: 58, recentNights: [.nan, 300, 64],
                                               deviceProvided: 0), 64)
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: nil, nightLowest: nil, recentNights: [],
                                               deviceProvided: 0), StrainScorer.defaultRestingHR)
    }
}
