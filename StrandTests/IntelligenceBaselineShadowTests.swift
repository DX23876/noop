import XCTest
import StrandAnalytics
@testable import Strand

/// Pins the baseline-merge precedence in `IntelligenceEngine.mergeNightlyIntoHistory` (the
/// "Needs the strap" / recovery-No-Data starvation). An imported history row that carries a
/// nil value for a metric holds no information for that day: it must NOT shadow the real
/// on-device nightly value into a permanently missing night, or an import whose rows are
/// blank for avgHrv/restingHr blankets every strap-covered day and the baseline never
/// crosses `Baselines.minNightsSeed`. Precedence pinned here:
///
///   1. imported non-nil  → wins over the computed value (import users unchanged)
///   2. key absent        → computed value fills (the BLE-only recovery fix)
///   3. imported nil      → computed value backfills (the shadow fix)
///   4. imported nil, no computed value → stays a missing night (honest gap)
///
/// Twin of the Kotlin `IntelligenceBaselineShadowTest` so both platforms merge identically.
final class IntelligenceBaselineShadowTests: XCTestCase {

    func testImportedNonNilWinsOverComputed() {
        var hist: [String: Double?] = ["2026-07-10": 62.0]
        IntelligenceEngine.mergeNightlyIntoHistory(&hist, ["2026-07-10": 48.0])
        XCTAssertEqual(hist["2026-07-10"]!, 62.0)
    }

    func testDayNotImportedComputedFills() {
        var hist: [String: Double?] = ["2026-07-10": 62.0]
        IntelligenceEngine.mergeNightlyIntoHistory(&hist, ["2026-07-11": 48.0])
        XCTAssertEqual(hist["2026-07-11"]!, 48.0)
        XCTAssertEqual(hist.count, 2)
    }

    func testImportedNilValueBackfilledByComputed() {
        // THE bug: the user's import wrote a row for the day with a blank avgHrv while the
        // strap actually scored the night. The blank row must not shadow the real value.
        var hist: [String: Double?] = ["2026-07-10": nil]
        IntelligenceEngine.mergeNightlyIntoHistory(&hist, ["2026-07-10": 48.0])
        XCTAssertEqual(
            hist["2026-07-10"]!, 48.0,
            "an imported row with a nil value must be backfilled by the real computed night")
    }

    func testImportedNilValueNoComputedStaysMissing() {
        var hist: [String: Double?] = ["2026-07-10": nil]
        IntelligenceEngine.mergeNightlyIntoHistory(&hist, [:])
        XCTAssertNotNil(hist.index(forKey: "2026-07-10"))
        XCTAssertNil(hist["2026-07-10"]!)
    }

    func testNilComputedDoesNotDisturbAnything() {
        // A computed pass that produced no value for a day it emitted (nil estimate) neither
        // overwrites an imported value nor un-registers an imported-nil day.
        var hist: [String: Double?] = ["2026-07-10": 62.0, "2026-07-11": nil]
        IntelligenceEngine.mergeNightlyIntoHistory(
            &hist, ["2026-07-10": nil, "2026-07-11": nil, "2026-07-12": nil])
        XCTAssertEqual(hist["2026-07-10"]!, 62.0)
        XCTAssertNil(hist["2026-07-11"]!)
        XCTAssertNotNil(hist.index(forKey: "2026-07-12"))
        XCTAssertNil(hist["2026-07-12"]!)
    }

    func testStarvationShapeEndToEnd() {
        // The report's shape: a week of imported rows, ALL blank for HRV, over nights the
        // strap scored. After the merge the fold input must contain the 7 real values, so
        // the baseline can cross Baselines.minNightsSeed instead of reading "No Data".
        var hist: [String: Double?] = [:]
        var nightly: [String: Double?] = [:]
        for i in stride(from: 6, through: 0, by: -1) {
            let day = String(format: "2026-07-%02d", 12 - i)
            hist[day] = Double?.none
            nightly[day] = 50.0 + Double(i)
        }
        IntelligenceEngine.mergeNightlyIntoHistory(&hist, nightly)
        let valid = hist.values.compactMap { $0 }
        XCTAssertEqual(valid.count, 7, "all 7 strap nights must survive the merge")
        XCTAssertGreaterThanOrEqual(valid.count, Baselines.minNightsSeed)
    }
}
