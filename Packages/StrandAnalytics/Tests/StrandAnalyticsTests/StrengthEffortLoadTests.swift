import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The strength share of Effort on the curve (#2438): session RPE × minutes × 0.11, added to the load before
/// the curve.
final class StrengthEffortLoadTests: XCTestCase {
    func testTheLoadIsRPETimesMinutesTimesTheFittedScale() {
        XCTAssertEqual(StrainScorer.strengthLoad(rpe: 7, minutes: 60), 46.2, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.strengthLoad(rpe: 0, minutes: 60), 0)
        XCTAssertEqual(StrainScorer.strengthLoad(rpe: 7, minutes: 0), 0)
        XCTAssertEqual(StrainScorer.strengthLoad(rpe: .nan, minutes: 60), 0)
    }

    /// A stored score takes a strength load on top through the inverse of the curve.
    func testTheInverseOfTheCurveRecoversTheLoad() {
        for load in [0.5, 5, 40, 200, 1_500, 6_000] {
            let value = StrainScorer.effortValue(load: load)
            let back = StrainScorer.effortLoad(forEffortValue: value)
            XCTAssertEqual(StrainScorer.effortValue(load: back), value, accuracy: 0.011, "load \(load)")
        }
        XCTAssertEqual(StrainScorer.effortLoad(forEffortValue: 0), 0)
        XCTAssertEqual(StrainScorer.effortValue(37, addingStrengthLoad: 0), 37)
    }

    /// The mean contributed strength session (52 minutes, WHOOP 11.2, heart-rate curve 9.2 on 0–21) lands near
    /// WHOOP at the assumed RPE 7.
    func testATypicalSessionMovesTowardWhoop() {
        let hrOnly = 9.2 / 21 * 100
        let withStrength = StrainScorer.effortValue(hrOnly, addingStrengthLoad: StrainScorer.strengthLoad(rpe: 7, minutes: 52))
        XCTAssertEqual(withStrength / 100 * 21, 11.2, accuracy: 0.6)
    }

    /// The day's score includes the strength load, and without it nothing changes.
    func testTheDayScoreTakesTheStrengthLoad() throws {
        let start = 1_000_000
        let hr = (0..<3_600).map { HRSample(ts: start + $0, bpm: 120) }
        let base = try XCTUnwrap(StrainScorer.strain(hr, maxHR: 190, restingHR: 60))
        let same = try XCTUnwrap(StrainScorer.strain(hr, maxHR: 190, restingHR: 60, strengthLoad: 0))
        let more = try XCTUnwrap(StrainScorer.strain(hr, maxHR: 190, restingHR: 60, strengthLoad: 46.2))
        XCTAssertEqual(base, same)
        XCTAssertGreaterThan(more, base)
        XCTAssertEqual(more, StrainScorer.effortValue(base, addingStrengthLoad: 46.2), accuracy: 0.05)
    }
}
