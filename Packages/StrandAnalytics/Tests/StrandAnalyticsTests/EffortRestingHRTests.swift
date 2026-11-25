import XCTest
@testable import StrandAnalytics

/// The resting heart rate Effort is scored against (#2438, 2026-11-25): the main night's mean, as the curve
/// was fitted on WHOOP's resting heart rate and not on a night's lowest five minutes.
final class EffortRestingHRTests: XCTestCase {

    func testTheNightsMeanWins() {
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: 61.4, recentNightMeans: [70, 71, 72], deviceProvided: 48),
                       61.4)
    }

    /// Without a night the median of the last seven nights stands in, the older ones ignored.
    func testWithoutANightTheLastSevenNightsStandIn() {
        let recent: [Double] = [90, 90, 90, 60, 62, 64, 66, 68, 70, 72]   // oldest first; the last seven: 66
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: nil, recentNightMeans: recent, deviceProvided: nil), 66)
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: nil, recentNightMeans: [60, 64], deviceProvided: nil), 62)
    }

    /// A device's own resting heart rate is a night's lowest reading, so it counts only with no heart-rate
    /// history at all; then the scorer's default.
    func testADevicesValueOnlyWithoutAnyNightAndThenTheDefault() {
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: nil, recentNightMeans: [], deviceProvided: 48), 48)
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: nil, recentNightMeans: [], deviceProvided: nil),
                       StrainScorer.defaultRestingHR)
    }

    /// The nights before a day: the last seven that have a mean, oldest first, skipping unworn days, never the
    /// day itself and never one past the lookback.
    func testTheNightsBeforeADay() {
        var means: [String: Double] = ["2026-11-20": 99, "2026-11-19": 70, "2026-11-17": 69,
                                       "2026-10-10": 50]
        for d in 10 ... 15 { means["2026-11-\(d)"] = Double(d + 50) }
        XCTAssertEqual(EffortRestingHR.nightsBefore("2026-11-20", in: means), [61, 62, 63, 64, 65, 69, 70])
        XCTAssertEqual(EffortRestingHR.nightsBefore("2026-11-01", in: ["2026-10-10": 50, "2026-09-01": 40]), [50])
    }

    /// A value no wearer can have is treated as missing, so one broken night cannot set a day's yardstick.
    func testImplausibleValuesAreMissing() {
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: 0, recentNightMeans: [.nan, 300, 64], deviceProvided: 0),
                       64)
        XCTAssertEqual(EffortRestingHR.resolve(nightMean: .infinity, recentNightMeans: [], deviceProvided: nil),
                       StrainScorer.defaultRestingHR)
    }
}
