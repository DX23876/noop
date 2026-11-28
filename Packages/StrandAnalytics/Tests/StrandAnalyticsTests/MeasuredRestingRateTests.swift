import XCTest
@testable import StrandAnalytics

/// A measured resting rate (owner decisions 2026-11-27, Q9 and the follow-up): kept as its ratio to
/// Mifflin–St Jeor on the measurement day, so it follows the body's weight; asked about past 40 %.
final class MeasuredRestingRateTests: XCTestCase {
    func testTheRatioFollowsTheBodyAfterwards() throws {
        let rate = try XCTUnwrap(MeasuredRestingRate.make(kcalPerDay: 3_300, day: "2026-12-01", weightKg: 200,
                                                          heightCm: 196, age: 35, sex: "male"))
        let atMeasurement = try XCTUnwrap(BasalRate.kcalPerDay(.mifflinStJeor, weightKg: 200, heightCm: 196,
                                                               age: 35, sex: "male"))
        XCTAssertEqual(rate.factor, 3_300 / atMeasurement, accuracy: 1e-12)
        var later = UserProfile(weightKg: 180, heightCm: 196, age: 35, sex: "male", basalFormula: .measured,
                                measuredBasalFactor: rate.factor)
        let mifflinLater = try XCTUnwrap(BasalRate.kcalPerDay(.mifflinStJeor, weightKg: 180, heightCm: 196,
                                                              age: 35, sex: "male"))
        XCTAssertEqual(try XCTUnwrap(Calories.bmrKcalPerDay(profile: later)), mifflinLater * rate.factor, accuracy: 1e-9)

        // "Measured" without a measurement falls back to Mifflin–St Jeor rather than to nothing.
        later.measuredBasalFactor = nil
        XCTAssertEqual(try XCTUnwrap(Calories.bmrKcalPerDay(profile: later)), mifflinLater, accuracy: 1e-9)
    }

    func testAValueFarFromTheEquationIsNotPlausibleAndNonsenseIsRefused() throws {
        let far = try XCTUnwrap(MeasuredRestingRate.make(kcalPerDay: 5_000, day: "2026-12-01", weightKg: 80,
                                                         heightCm: 180, age: 35, sex: "male"))
        XCTAssertFalse(far.isPlausible)
        XCTAssertNil(MeasuredRestingRate.make(kcalPerDay: 90, day: "2026-12-01", weightKg: 80, heightCm: 180,
                                              age: 35, sex: "male"))
    }

    func testARoundTripAndAgeOfTheMeasurement() throws {
        let rate = MeasuredRestingRate(kcalPerDay: 3_300, day: "2025-11-01", factor: 1.08)
        XCTAssertEqual(MeasuredRestingRate.decode(rate.encodedJSON()), rate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27)))
        XCTAssertTrue(rate.isOld(today: today, calendar: calendar))
    }

    /// A profile without a measurement keeps the cache key it always had, so no cached day is invalidated.
    func testTheCacheKeyIsUnchangedWithoutAMeasurement() {
        let plain = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male", basalFormula: .mifflinStJeor)
        XCTAssertFalse(plain.cacheKey.contains(",m="))
        var measured = plain
        measured.measuredBasalFactor = 1.05
        XCTAssertNotEqual(plain.cacheKey, measured.cacheKey)
    }
}
