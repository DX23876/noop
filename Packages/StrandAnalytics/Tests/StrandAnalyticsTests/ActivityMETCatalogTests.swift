import XCTest
@testable import StrandAnalytics

final class ActivityMETCatalogTests: XCTestCase {
    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")

    func testOneMETHourCostsOneKcalPerKilogram() {
        // The definition the whole table rests on, pinned once so a refactor cannot quietly rescale it.
        let met = ActivityMETCatalog.met(forSport: "Strength")
        XCTAssertEqual(ActivityMETCatalog.grossKcal(sport: "Strength", seconds: 3_600, weightKg: 80) ?? 0,
                       met * 80, accuracy: 0.001)
        XCTAssertEqual(ActivityMETCatalog.grossKcal(sport: "Strength", seconds: 1_800, weightKg: 80) ?? 0,
                       met * 80 / 2, accuracy: 0.001)
    }

    func testSportNamesMatchRegardlessOfSpellingAndUnknownOnesFallBack() {
        let expected = ActivityMETCatalog.met(forSport: "Open-water swim")
        for spelling in ["open-water swim", "Open-Water Swim", "openwaterswim", "Open water swim"] {
            XCTAssertEqual(ActivityMETCatalog.met(forSport: spelling), expected, spelling)
        }
        // Free text is allowed everywhere in the app, so the table must answer without inventing.
        XCTAssertEqual(ActivityMETCatalog.met(forSport: "Underwater basket weaving"),
                       ActivityMETCatalog.defaultMET)
        XCTAssertEqual(ActivityMETCatalog.met(forSport: ""), ActivityMETCatalog.defaultMET)
    }

    func testTheTableOrdersActivitiesTheWayPhysiologyDoes() {
        XCTAssertLessThan(ActivityMETCatalog.met(forSport: "Meditation"),
                          ActivityMETCatalog.met(forSport: "Yoga"))
        XCTAssertLessThan(ActivityMETCatalog.met(forSport: "Yoga"),
                          ActivityMETCatalog.met(forSport: "Walking"))
        XCTAssertLessThan(ActivityMETCatalog.met(forSport: "Walking"),
                          ActivityMETCatalog.met(forSport: "Strength"))
        XCTAssertLessThan(ActivityMETCatalog.met(forSport: "Strength"),
                          ActivityMETCatalog.met(forSport: "Running"))
        XCTAssertLessThan(ActivityMETCatalog.met(forSport: "Running"),
                          ActivityMETCatalog.met(forSport: "Jump rope"))
    }

    func testNoBodyMassMeansNoEstimate() {
        XCTAssertNil(ActivityMETCatalog.grossKcal(sport: "Running", seconds: 3_600, weightKg: 0))
        XCTAssertNil(ActivityMETCatalog.grossKcal(sport: "Running", seconds: 0, weightKg: 80))
        XCTAssertNil(ActivityMETCatalog.grossKcal(sport: "Running", seconds: .nan, weightKg: 80))
    }

    // MARK: - The average-HR estimator that outranks the table

    func testAverageHeartRateEstimateTracksIntensity() {
        func kcal(_ bpm: Int) -> Double {
            Calories.estimateBoutCalories(averageHR: bpm, durationSeconds: 3_600, profile: profile,
                                          hrmax: 190, restingHR: 55) ?? 0
        }
        // Recovering the SHAPE, not one point: a harder hour must cost more than an easier one, all
        // the way up, or the estimate is not reading heart rate at all.
        let series = [100, 120, 140, 160, 180].map(kcal)
        XCTAssertEqual(series, series.sorted())
        XCTAssertGreaterThan(series[0], 0)
        // Below the activity gate the window is resting energy, not exercise energy — an hour of it
        // must stay near an hour of basal rather than crossing into Keytel territory.
        let quiet = kcal(58)
        XCTAssertLessThan(quiet, (Calories.bmrKcalPerDay(profile: profile) ?? 0) / 24 * 1.5)
    }

    func testAverageHeartRateEstimateScalesWithDurationAndRejectsNonsense() {
        let hour = Calories.estimateBoutCalories(averageHR: 150, durationSeconds: 3_600,
                                                 profile: profile, hrmax: 190, restingHR: 55) ?? 0
        let half = Calories.estimateBoutCalories(averageHR: 150, durationSeconds: 1_800,
                                                 profile: profile, hrmax: 190, restingHR: 55) ?? 0
        XCTAssertEqual(hour, half * 2, accuracy: 0.001)
        XCTAssertNil(Calories.estimateBoutCalories(averageHR: 0, durationSeconds: 3_600,
                                                   profile: profile, hrmax: 190, restingHR: 55))
        XCTAssertNil(Calories.estimateBoutCalories(averageHR: 150, durationSeconds: 0,
                                                   profile: profile, hrmax: 190, restingHR: 55))
    }
}
