import XCTest
@testable import StrandAnalytics

/// #2438: the one resolver for the wearer's maximum heart rate.
///
/// The first version must return exactly what each hand-written expression it replaced returned, so the
/// legacy expressions are written out here once more and compared over every age and setting. Step 0
/// changes the rule; these equality tests are then replaced by the new rule's cases, not loosened.
/// `Tools/test_max_heart_rate_resolver.py` pins that no product source resolves the value by itself.
final class MaxHeartRateTests: XCTestCase {

    private struct Case { let override: Double?; let age: Double; let bpm: Double?; let source: MaxHeartRate.Source }

    // The case table of bartmuskala's `EffortHRmaxResolverTests`, which this resolver is modelled on.
    private let cases: [Case] = [
        Case(override: nil, age: 30.0, bpm: 187.0, source: .tanaka),
        Case(override: nil, age: 37.0, bpm: 182.1, source: .tanaka),
        Case(override: 195.0, age: 30.0, bpm: 195.0, source: .override),
        // A setting wins without an age: it is the wearer's own number and needs nothing else.
        Case(override: 195.0, age: 0.0, bpm: 195.0, source: .override),
        // A setting BELOW the formula is still the setting, never max(setting, formula).
        Case(override: 150.0, age: 80.0, bpm: 150.0, source: .override),
        // Neither: nil, which `StrainScorer.strain` replaces with `defaultMaxHR()`.
        Case(override: nil, age: 0.0, bpm: nil, source: .default),
        Case(override: nil, age: -1.0, bpm: nil, source: .default),
    ]

    func testEveryCaseResolvesToItsValueAndItsSource() {
        for c in cases {
            let r = MaxHeartRate.resolve(override: c.override, age: c.age)
            XCTAssertEqual(r.source, c.source, "source for \(c)")
            if let want = c.bpm {
                XCTAssertEqual(r.bpm ?? -1, want, accuracy: 1e-9, "bpm for \(c)")
            } else {
                XCTAssertNil(r.bpm, "bpm for \(c)")
            }
        }
    }

    func testStoredSettingZeroOrLessMeansNoSetting() {
        XCTAssertEqual(MaxHeartRate.resolve(overrideBpm: 0, age: 40), MaxHeartRate.resolve(override: nil, age: 40))
        XCTAssertEqual(MaxHeartRate.resolve(overrideBpm: -5, age: 40), MaxHeartRate.resolve(override: nil, age: 40))
        XCTAssertEqual(MaxHeartRate.resolve(overrideBpm: 196, age: 40).bpm, 196)
    }

    /// The unrounded form equals the expression the day pass, the healthspan age, the cycle path and
    /// the Today views wrote by hand: `override > 0 ? override : (age > 0 ? tanaka(age) : nil)`.
    func testBpmEqualsTheReplacedDoubleExpression() {
        for overrideBpm in [0, 150, 187, 196, 230] {
            for age in 0...100 {
                let legacy: Double? = overrideBpm > 0
                    ? Double(overrideBpm)
                    : (age > 0 ? 208.0 - 0.7 * Double(age) : nil)
                XCTAssertEqual(MaxHeartRate.resolve(overrideBpm: overrideBpm, age: Double(age)).bpm, legacy,
                               "override \(overrideBpm) age \(age)")
            }
        }
    }

    /// The whole-bpm form equals `ProfileStore.hrMax` as it was written:
    /// `override > 0 ? override : Int((208 - 0.7 * age).rounded())`, including 208 for age 0.
    func testWholeBpmEqualsTheReplacedProfileExpression() {
        for overrideBpm in [0, 150, 187, 196, 230] {
            for age in 0...100 {
                let legacy = overrideBpm > 0 ? overrideBpm : Int((208 - 0.7 * Double(age)).rounded())
                XCTAssertEqual(MaxHeartRate.resolve(overrideBpm: overrideBpm, age: Double(age)).wholeBpm, legacy,
                               "override \(overrideBpm) age \(age)")
            }
        }
    }

    /// The formula-only readers (VO₂max fallback, energy fallback) keep ignoring the setting until step 0.
    func testAgeFormulaIgnoresTheSettingAndNeedsAnAge() {
        XCTAssertEqual(MaxHeartRate.ageFormula(age: 30), 187.0)
        XCTAssertNil(MaxHeartRate.ageFormula(age: 0))
        for age in 1...100 {
            XCTAssertEqual(MaxHeartRate.ageFormula(age: Double(age)), StrainScorer.tanakaHRmax(age: Double(age)))
        }
    }

    /// The zones' age entry point keeps its old answers, including the formula at age 0.
    func testZonesFromAgeKeepTheirMaximumAndSource() {
        XCTAssertEqual(HRZones.zones(age: 30).maxHR, 187.0, accuracy: 1e-9)
        XCTAssertEqual(HRZones.zones(age: 30).source, "tanaka")
        XCTAssertEqual(HRZones.zones(age: 0).maxHR, 208.0, accuracy: 1e-9)
        XCTAssertEqual(HRZones.zones(age: 30, maxHROverride: 195).maxHR, 195.0, accuracy: 1e-9)
        XCTAssertEqual(HRZones.zones(age: 30, maxHROverride: 195).source, "manual")
    }
}
