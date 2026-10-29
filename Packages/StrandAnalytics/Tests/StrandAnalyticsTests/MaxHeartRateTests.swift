import XCTest
@testable import StrandAnalytics

/// #2438 step 0: the one resolver for the wearer's maximum heart rate, and the measured level it reads.
/// `Tools/test_max_heart_rate_resolver.py` pins that no product source resolves the value by itself.
final class MaxHeartRateTests: XCTestCase {

    // MARK: - Gellish

    /// Gellish et al. (2007), 192 − 0.007 × age², in whole bpm.
    func testGellishIsTheFormulaRoundedToAWholeBeat() {
        XCTAssertEqual(MaxHeartRate.gellish(age: 30), 186)   // 185.7
        XCTAssertEqual(MaxHeartRate.gellish(age: 40), 181)   // 180.8
        XCTAssertEqual(MaxHeartRate.gellish(age: 66), 162)   // 161.508
        XCTAssertNil(MaxHeartRate.gellish(age: 0))
        XCTAssertNil(MaxHeartRate.gellish(age: -1))
    }

    // MARK: - resolve

    private struct Case { let override: Double?; let age: Double; let measured: Double?; let bpm: Double?; let source: MaxHeartRate.Source }

    private let cases: [Case] = [
        Case(override: nil, age: 30, measured: nil, bpm: 186, source: .gellish),
        Case(override: 195, age: 30, measured: nil, bpm: 195, source: .override),
        // A setting wins over a measured level, also a lower setting: it is the wearer's own number.
        Case(override: 180, age: 30, measured: 194, bpm: 180, source: .override),
        // A setting needs no age.
        Case(override: 195, age: 0, measured: nil, bpm: 195, source: .override),
        Case(override: nil, age: 30, measured: 194, bpm: 194, source: .measured),
        // A level below the formula is no evidence of a lower maximum: the formula stays.
        Case(override: nil, age: 30, measured: 180, bpm: 186, source: .gellish),
        // A level at the formula reads as measured, with the same value.
        Case(override: nil, age: 30, measured: 186, bpm: 186, source: .measured),
        // A decayed level is a whole bpm like every other value.
        Case(override: nil, age: 30, measured: 193.6, bpm: 194, source: .measured),
        // No age: a measured level is still a measurement; without one, nothing.
        Case(override: nil, age: 0, measured: 190, bpm: 190, source: .measured),
        Case(override: nil, age: 0, measured: nil, bpm: nil, source: .default),
    ]

    func testEveryCaseResolvesToItsValueAndItsSource() {
        for c in cases {
            let r = MaxHeartRate.resolve(override: c.override, age: c.age, measured: c.measured)
            XCTAssertEqual(r.source, c.source, "source for \(c)")
            XCTAssertEqual(r.bpm, c.bpm, "bpm for \(c)")
        }
    }

    func testStoredSettingZeroOrLessMeansNoSetting() {
        XCTAssertEqual(MaxHeartRate.resolve(overrideBpm: 0, age: 40), MaxHeartRate.resolve(override: nil, age: 40))
        XCTAssertEqual(MaxHeartRate.resolve(overrideBpm: -5, age: 40), MaxHeartRate.resolve(override: nil, age: 40))
        XCTAssertEqual(MaxHeartRate.resolve(overrideBpm: 196, age: 40).bpm, 196)
    }

    /// Every reader sees one whole number; an age-less profile reads the scorer's own default.
    func testWholeBpmIsTheValueAndTheScorersDefaultWithoutOne() {
        for age in 1...100 {
            let r = MaxHeartRate.resolve(override: nil, age: Double(age))
            XCTAssertEqual(Double(r.wholeBpm), r.bpm)
        }
        XCTAssertEqual(MaxHeartRate.resolve(override: nil, age: 0).wholeBpm, StrainScorer.defaultMaxHR())
    }

    // MARK: - measured levels

    private let age = 30.0   // Gellish 186, plausibility bound 211
    private let slope = 0.014 * 30 / 365.25   // bpm a day

    func testOneDayIsNotALevel() {
        let levels = MaxHeartRate.measuredLevels(days: ["2026-10-10"], peaks: ["2026-10-01": 195], age: age)
        XCTAssertNil(levels["2026-10-10"])
    }

    /// The level is the second-highest day: the value reached on at least two days.
    func testTwoDaysConfirmTheLowerOfTheTwo() {
        let peaks = ["2026-10-01": 197.0, "2026-10-03": 193, "2026-10-05": 190]
        let levels = MaxHeartRate.measuredLevels(days: ["2026-10-10"], peaks: peaks, age: age)
        XCTAssertEqual(levels["2026-10-10"]?.bpm ?? 0, 193 - slope * 7, accuracy: 1e-9)
        XCTAssertEqual(levels["2026-10-10"]?.confirmedOn, "2026-10-03")
    }

    /// A day reads only the days before it, so its own workouts cannot move its own value.
    func testADayDoesNotCountItsOwnPeak() {
        let peaks = ["2026-10-01": 195.0, "2026-10-05": 195]
        let levels = MaxHeartRate.measuredLevels(days: ["2026-10-05", "2026-10-06"], peaks: peaks, age: age)
        XCTAssertNil(levels["2026-10-05"])
        XCTAssertEqual(levels["2026-10-06"]?.bpm ?? 0, 195 - slope, accuracy: 1e-9)
    }

    /// A peak more than 25 bpm above the formula is an artefact and confirms nothing.
    func testAnImplausiblePeakIsIgnored() {
        let peaks = ["2026-10-01": 230.0, "2026-10-02": 229, "2026-10-03": 192]
        let levels = MaxHeartRate.measuredLevels(days: ["2026-10-10"], peaks: peaks, age: age)
        XCTAssertNil(levels["2026-10-10"])
        let atBound = ["2026-10-01": 211.0, "2026-10-02": 211]
        XCTAssertEqual(MaxHeartRate.measuredLevels(days: ["2026-10-10"], peaks: atBound, age: age)["2026-10-10"]?.bpm ?? 0,
                       211 - slope * 8, accuracy: 1e-9)
    }

    /// Once the confirming days leave the 90-day window the level stays, falling only by Gellish's slope
    /// at this age (0.42 bpm a year at 30), counted from the later day that reached it.
    func testAQuietStretchKeepsTheLevelAndDecaysItWithAge() throws {
        let peaks = ["2025-01-01": 195.0, "2025-01-02": 195]
        let oneYearOn = HealthspanWindow.dayKey("2025-01-03", plus: 365)
        let levels = MaxHeartRate.measuredLevels(days: ["2025-01-03", oneYearOn], peaks: peaks, age: age)
        XCTAssertEqual(levels["2025-01-03"]?.bpm ?? 0, 195 - slope, accuracy: 1e-9)
        let later = try XCTUnwrap(levels[oneYearOn])
        XCTAssertEqual(later.bpm, 195 - slope * 366, accuracy: 1e-9)
        XCTAssertEqual(later.confirmedOn, "2025-01-02")
    }

    /// A higher level replaces the carried one; a lower window level does not pull it down.
    func testAHigherLevelReplacesTheCarriedOneAndALowerOneDoesNot() {
        let peaks = ["2026-01-01": 190.0, "2026-01-02": 190,
                     "2026-06-01": 185, "2026-06-02": 185,
                     "2026-09-01": 198, "2026-09-02": 196]
        let levels = MaxHeartRate.measuredLevels(days: ["2026-06-10", "2026-09-10"], peaks: peaks, age: age)
        XCTAssertEqual(levels["2026-06-10"]?.bpm ?? 0, 190 - slope * 159, accuracy: 1e-9)
        XCTAssertEqual(levels["2026-09-10"]?.bpm ?? 0, 196 - slope * 8, accuracy: 1e-9)
    }

    func testNoPeaksMeanNoLevel() {
        XCTAssertTrue(MaxHeartRate.measuredLevels(days: ["2026-10-10"], peaks: [:], age: age).isEmpty)
        XCTAssertTrue(MaxHeartRate.measuredLevels(days: [], peaks: ["2026-10-01": 195], age: age).isEmpty)
    }

    func testTheStoredFormRoundTrips() {
        let level = MaxHeartRate.Level(bpm: 193.4, confirmedOn: "2026-10-04")
        XCTAssertEqual(level.stored, "193|2026-10-04")
        XCTAssertEqual(MaxHeartRate.Level(stored: level.stored), MaxHeartRate.Level(bpm: 193, confirmedOn: "2026-10-04"))
        XCTAssertNil(MaxHeartRate.Level(stored: nil))
        XCTAssertNil(MaxHeartRate.Level(stored: "0|2026-10-04"))
        XCTAssertNil(MaxHeartRate.Level(stored: "garbage"))
    }

    // MARK: - zones

    func testZonesFromAgeReadTheResolver() {
        XCTAssertEqual(HRZones.zones(age: 30).maxHR, 186)
        XCTAssertEqual(HRZones.zones(age: 30).source, "gellish")
        XCTAssertEqual(HRZones.zones(age: 30, maxHROverride: 195).maxHR, 195)
        XCTAssertEqual(HRZones.zones(age: 30, maxHROverride: 195).source, "manual")
    }
}
