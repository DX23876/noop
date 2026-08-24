import XCTest
import StrandAnalytics
@testable import Strand

/// `WeightSeries.displayWeight` — which of the three weights a Today tile shows, and what it calls it.
///
/// The tier is not cosmetic: "80.0 kg" means a smoothed trend, a scale reading, or a number the user
/// typed into their profile months ago, and the caption is the only thing telling them which.
final class WeightDisplayTierTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func summary(latest: Double, trend: Double, reliable: Bool) -> WeightTrendSummary {
        WeightTrendSummary(latestKg: latest, latestAt: now, trendKg: trend, isTrendReliable: reliable,
                           change7dKg: nil, change30dKg: nil, ratePerWeekKg: nil, readingCount: 9)
    }

    /// A settled trend wins — it is the number the weight goal is judged on, and showing the raw
    /// reading beside a goal measured on the trend put two weights for one body on one screen.
    func testSettledTrendWins() {
        let r = WeightSeries.displayWeight(summary: summary(latest: 79.9, trend: 80.4, reliable: true),
                                           profileWeightKg: 75)
        XCTAssertEqual(r.kg, 80.4)
        XCTAssertEqual(r.tier, .trend)
    }

    /// A trend folded from two weigh-ins is not a trend. Falling back to the last real measurement is
    /// more honest than dressing up a cold start.
    func testUnsettledTrendFallsBackToTheMeasurement() {
        let r = WeightSeries.displayWeight(summary: summary(latest: 79.9, trend: 80.4, reliable: false),
                                           profileWeightKg: 75)
        XCTAssertEqual(r.kg, 79.9)
        XCTAssertEqual(r.tier, .measured)
    }

    /// Nobody has ever weighed in: the profile value is all there is, and the tier says so.
    func testNoHistoryFallsBackToProfile() {
        let r = WeightSeries.displayWeight(summary: nil, profileWeightKg: 75)
        XCTAssertEqual(r.kg, 75)
        XCTAssertEqual(r.tier, .profile)
    }

    /// The same `> 10 kg` guard the rest of the app applies: a stray 0/garbage sample must not become
    /// the displayed body weight, however it got into the series.
    func testGarbageTrendIsRejected() {
        let r = WeightSeries.displayWeight(summary: summary(latest: 79.9, trend: 0.4, reliable: true),
                                           profileWeightKg: 75)
        XCTAssertEqual(r.kg, 79.9, "an implausible trend must not outrank a real measurement")
        XCTAssertEqual(r.tier, .measured)
    }

    func testGarbageEverywhereFallsThroughToProfile() {
        let r = WeightSeries.displayWeight(summary: summary(latest: 0.2, trend: 0.4, reliable: true),
                                           profileWeightKg: 75)
        XCTAssertEqual(r.kg, 75)
        XCTAssertEqual(r.tier, .profile)
    }
}
