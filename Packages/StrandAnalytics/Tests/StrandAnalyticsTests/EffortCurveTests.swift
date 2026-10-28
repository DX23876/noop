import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #2438 step 1: the Effort curve fitted on WHOOP's Strain of the contributed workouts.
///
/// The example days are the fit tool's own (`SCENARIOS` and `BELOW_SCENARIOS` in DX23876/effort-calibration),
/// built here as heart-rate series held at each zone's midpoint, so the scorer that runs on every reading is
/// checked against the tool that fitted the constants on minutes per zone. Expected values: the tool's report
/// of 2026-10-28 on the 15 exports, on WHOOP's 0–21 axis, ±0.1.
final class EffortCurveTests: XCTestCase {

    // Resting 60 and maximum 160 put x % HRR at exactly 60 + x bpm.
    private let resting = 60.0
    private let maximum = 160.0

    /// Minutes at each intensity (% HRR), in order, one reading a second.
    private func series(_ blocks: [(minutes: Int, pctHRR: Int)]) -> [HRSample] {
        var out: [HRSample] = []
        var ts = 1_790_000_000
        for block in blocks {
            for _ in 0 ..< block.minutes * 60 {
                out.append(HRSample(ts: ts, bpm: 60 + block.pctHRR))
                ts += 1
            }
        }
        return out
    }

    /// Minutes in zones 1 to 5, at their midpoints 55 to 95 % HRR.
    private func zones(_ minutes: [Int]) -> [HRSample] {
        series(zip(minutes, [55, 65, 75, 85, 95]).filter { $0.0 > 0 }.map { (minutes: $0.0, pctHRR: $0.1) })
    }

    private func score21(_ hr: [HRSample], _ low: StrainScorer.LowIntensity = .counted) throws -> Double {
        let effort = try XCTUnwrap(StrainScorer.strain(hr, maxHR: maximum, restingHR: resting, lowIntensity: low))
        return effort / StrainScorer.maxStrain * StrainScorer.whoopMaxStrain
    }

    func testTheExampleDaysOfTheFit() throws {
        let days: [(String, [Int], Double)] = [
            ("30-minute brisk walk", [30, 0, 0, 0, 0], 6.8),
            ("45-minute walk", [20, 25, 0, 0, 0], 10.0),
            ("1 h zone 3", [0, 0, 60, 0, 0], 15.1),
            ("1 h zone 4", [0, 0, 0, 60, 0], 17.5),
            ("90 min intervals", [0, 20, 30, 30, 10], 18.2),
            ("Marathon 3:30", [0, 0, 30, 150, 30], 20.4),
            ("10 h ultra", [0, 300, 300, 0, 0], 20.6),
        ]
        for (name, minutes, expected) in days {
            XCTAssertEqual(try score21(zones(minutes)), expected, accuracy: 0.1, name)
        }
    }

    func testTimeBelowZoneOneInAWorkout() throws {
        XCTAssertEqual(try score21(series([(60, 15)])), 0.4, accuracy: 0.1, "60 min stroll at 15 % HRR")
        XCTAssertEqual(try score21(series([(60, 35)])), 5.2, accuracy: 0.1, "60 min easy walk at 35 % HRR")
    }

    /// Below 50 % HRR only workout time counts: ten hours on one's feet at 25 % HRR are no Effort outside a
    /// workout, and the curve's value inside one.
    func testLowIntensityCountsOnlyInsideWorkouts() throws {
        let day = series([(600, 25)])
        XCTAssertEqual(try score21(day, .countedIn([])), 0)
        XCTAssertGreaterThan(try score21(day, .counted), 5)
        let first = day[0].ts
        let oneHourInAWorkout = try score21(day, .countedIn([first ..< first + 3_600]))
        XCTAssertEqual(oneHourInAWorkout, try score21(series([(60, 25)])), accuracy: 0.01)
        // From 50 % HRR every reading counts, workout or not.
        let tempo = series([(60, 75)])
        XCTAssertEqual(try score21(tempo, .countedIn([])), try score21(tempo, .counted), accuracy: 1e-9)
    }

    /// A resting day scores nothing; a day held at the top for 24 hours stays below 21.
    func testTheEndsOfTheScale() throws {
        XCTAssertEqual(try score21(series([(600, 0)]), .countedIn([])), 0)
        let allDay = try score21(zones([0, 0, 0, 0, 1_440]))
        XCTAssertEqual(allDay, 20.97, accuracy: 0.02)
        XCTAssertLessThan(allDay, 21)
        XCTAssertLessThan(StrainScorer.effortValue(load: 1e12), StrainScorer.maxStrain)
    }

    func testTheScoreRisesStrictlyWithLoad() {
        var last = -1.0
        for load in stride(from: 0.0, through: 5_000, by: 0.5) {
            let s = StrainScorer.effortScore21(load: load)
            XCTAssertGreaterThan(s, last, "load \(load)")
            last = s
        }
    }

    /// The weight is 1 at zone 1's midpoint and grows by e^0.5646 per 10 % HRR; below 20 % HRR it fades out.
    func testTheWeightOfAMinute() {
        XCTAssertEqual(StrainScorer.effortWeight(pctHRR: 55), 1, accuracy: 1e-4)
        XCTAssertEqual(StrainScorer.effortWeight(pctHRR: 65) / StrainScorer.effortWeight(pctHRR: 55),
                       exp(0.5646), accuracy: 1e-4)
        XCTAssertEqual(StrainScorer.effortWeight(pctHRR: 20),
                       0.5 * exp(0.5646 * (20 - 55) / 10), accuracy: 1e-12)
        XCTAssertLessThan(StrainScorer.effortWeight(pctHRR: 5), 0.001)
    }
}
