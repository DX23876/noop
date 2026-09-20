import XCTest
@testable import StrandAnalytics

final class Spo2DisplayTests: XCTestCase {

    private func resolve(today: Double? = nil, candidate: Double? = nil,
                         enabled: Bool = true, carried: Double? = nil) -> Spo2Display.Resolved? {
        Spo2Display.resolve(todayPct: today, candidatePct: candidate,
                            candidateEnabled: enabled, carriedPct: carried)
    }

    /// THE regression. An import that ended months ago left a calibrated value in the carry, and the
    /// old rule let it beat every fresh estimate — so the tile showed 1 June until August and hid the
    /// reading the strap had produced that night.
    func testTonightsEstimateBeatsAMonthsOldMeasurement() {
        let out = resolve(candidate: 95, carried: 97)
        XCTAssertEqual(out?.percent, 95)
        XCTAssertEqual(out?.provenance, .candidate)
    }

    /// The other side of the same rule: within ONE day a measurement still beats an estimate. The
    /// change is about recency across days, not about trusting the candidate more.
    func testTodaysMeasurementBeatsTodaysEstimate() {
        let out = resolve(today: 96, candidate: 93)
        XCTAssertEqual(out?.percent, 96)
        XCTAssertEqual(out?.provenance, .measured)
    }

    /// With the toggle off the candidate does not exist for this decision — the carry is then the
    /// only thing left, exactly as before the experiment shipped.
    func testWithTheToggleOffTheCarryIsUsed() {
        let out = resolve(candidate: 95, enabled: false, carried: 97)
        XCTAssertEqual(out?.percent, 97)
        XCTAssertEqual(out?.provenance, .measuredCarried)
    }

    /// A carry with no candidate still shows, and says it is a carry so the surface can date it.
    func testACarryAloneIsStillShownAndMarked() {
        XCTAssertEqual(resolve(carried: 97)?.provenance, .measuredCarried)
    }

    func testNothingAtAllResolvesToNil() {
        XCTAssertNil(resolve())
        XCTAssertNil(resolve(candidate: 95, enabled: false))
    }

    /// Zero and NaN are "no reading", not a reading of zero percent — a 0 % blood oxygen would be a
    /// claim about a corpse, and it reaches these fields from empty rows and failed decodes.
    func testAZeroOrNaNReadingIsNotAReading() {
        XCTAssertEqual(resolve(today: 0, carried: 97)?.provenance, .measuredCarried)
        XCTAssertEqual(resolve(today: .nan, candidate: 95)?.provenance, .candidate)
        XCTAssertNil(resolve(today: 0, candidate: 0, carried: 0))
    }
}
