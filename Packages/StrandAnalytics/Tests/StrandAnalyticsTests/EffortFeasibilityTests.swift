import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The reported defect: the coach prescribed "20 min Zone 2, effort 15", which its own Effort maths
/// cannot produce. These pin the arithmetic that makes such a target impossible to record.
final class EffortFeasibilityTests: XCTestCase {

    /// A representative wearer: HRmax 190, resting 50. Standard display bands.
    private let zoneSet = HRZones.zones(maxHR: 190)
    private let restingHR: Double = 50

    /// THE reported case: the coach offered 15 for a 20-minute Zone 2 ride. What the session is
    /// TYPICALLY worth is in the thirties — the wearer's own "27 or so" was the right order, and 15 is
    /// far enough away that the app must override it rather than record it.
    func testTwentyMinutesInZoneTwoIsWorthFarMoreThanFifteen() throws {
        let range = try XCTUnwrap(
            EffortFeasibility.sessionEffortRange(zone: 2, minutes: 20, zoneSet: zoneSet, restingHR: restingHR))
        XCTAssertGreaterThan(range.typical, 27, "typical was \(range.typical); the report put it around 27+")
        XCTAssertGreaterThan(range.distanceFromTypical(15), EffortFeasibility.targetTolerance,
                             "15 must be far enough from \(range.typical) to be overridden")
    }

    /// The honest floor of a DISPLAY band can be zero, because the band straddles an Edwards threshold
    /// — 46 % HRR at the bottom of Zone 2 is below the 50 % cut-off. That is a real property of the two
    /// zone models, and the reason `typical` exists: prescribing against the floor would be its own
    /// kind of nonsense.
    func testTheBandFloorCanBeZeroWhichIsWhyTypicalExists() throws {
        let range = try XCTUnwrap(
            EffortFeasibility.sessionEffortRange(zone: 2, minutes: 20, zoneSet: zoneSet, restingHR: restingHR))
        XCTAssertEqual(range.low, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(range.typical, range.low)
        XCTAssertGreaterThanOrEqual(range.high, range.typical)
    }

    /// A coach leaning slightly easy inside a band is judgement, not an error, and must survive. Only a
    /// figure the arithmetic can't support gets overridden.
    func testASmallDeliberateLeanIsWithinTolerance() throws {
        let range = try XCTUnwrap(
            EffortFeasibility.sessionEffortRange(zone: 3, minutes: 40, zoneSet: zoneSet, restingHR: restingHR))
        XCTAssertLessThanOrEqual(range.distanceFromTypical(range.typical - 4),
                                 EffortFeasibility.targetTolerance)
    }

    /// Longer is never worth less. Guards against a sign or log-map slip that would let the check
    /// approve a shorter-is-harder plan.
    func testEffortIsMonotonicInDuration() throws {
        var previous = 0.0
        for minutes in [10.0, 20, 30, 45, 60, 90] {
            let range = try XCTUnwrap(
                EffortFeasibility.sessionEffortRange(zone: 3, minutes: minutes,
                                                     zoneSet: zoneSet, restingHR: restingHR))
            XCTAssertGreaterThan(range.high, previous, "\(minutes) min was not worth more than the step below")
            previous = range.high
        }
    }

    /// Harder is never worth less, at a fixed duration.
    func testEffortIsMonotonicInZone() throws {
        var previous = -1.0
        for zone in 1...5 {
            let range = try XCTUnwrap(
                EffortFeasibility.sessionEffortRange(zone: zone, minutes: 30,
                                                     zoneSet: zoneSet, restingHR: restingHR))
            XCTAssertGreaterThanOrEqual(range.high, previous, "Zone \(zone) was worth less than Zone \(zone - 1)")
            previous = range.high
        }
    }

    /// The estimate must agree with the shipped scorer, not merely resemble it: a constant-HR stream
    /// run through `StrainScorer.strain` has to land inside the range this predicts for that zone.
    /// This is what stops the two from drifting apart if the Edwards weights or the log map ever move.
    func testAgreesWithTheShippedScorerOnAConstantStream() throws {
        let minutes = 30.0
        let band = zoneSet.zones[2]                      // Zone 3
        let midBpm = (band.lower + band.upper) / 2
        let samples = (0..<Int(minutes * 60)).map { HRSample(ts: $0, bpm: Int(midBpm.rounded())) }

        let scored = try XCTUnwrap(StrainScorer.strain(samples, maxHR: zoneSet.maxHR, restingHR: restingHR))
        let range = try XCTUnwrap(
            EffortFeasibility.sessionEffortRange(zone: 3, minutes: minutes,
                                                 zoneSet: zoneSet, restingHR: restingHR))

        XCTAssertGreaterThanOrEqual(scored, range.low - 0.01,
                                    "the real scorer produced \(scored), below the predicted floor \(range.low)")
        XCTAssertLessThanOrEqual(scored, range.high + 0.01,
                                 "the real scorer produced \(scored), above the predicted ceiling \(range.high)")
    }

    /// Custom bands change the answer — which is the whole reason this reads the wearer's zone set
    /// rather than the textbook one. A Zone 2 that starts higher is worth more.
    func testCustomBandsChangeWhatAZoneIsWorth() throws {
        let raised = HRZones.zones(
            config: HRZoneConfig(mode: .percent, percentLowerBounds: [0.60, 0.72, 0.80, 0.88, 0.94]),
            maxHR: 190)
        let standard = try XCTUnwrap(
            EffortFeasibility.sessionEffortRange(zone: 2, minutes: 30, zoneSet: zoneSet, restingHR: restingHR))
        let custom = try XCTUnwrap(
            EffortFeasibility.sessionEffortRange(zone: 2, minutes: 30, zoneSet: raised, restingHR: restingHR))
        XCTAssertGreaterThan(custom.typical, standard.typical,
                             "a Zone 2 that starts higher must be worth more, not the same")
    }

    /// Nothing to say rather than a number built on nothing.
    func testRefusesImpossibleInputs() {
        XCTAssertNil(EffortFeasibility.sessionEffortRange(zone: 2, minutes: 0, zoneSet: zoneSet, restingHR: restingHR))
        XCTAssertNil(EffortFeasibility.sessionEffortRange(zone: 0, minutes: 30, zoneSet: zoneSet, restingHR: restingHR))
        XCTAssertNil(EffortFeasibility.sessionEffortRange(zone: 6, minutes: 30, zoneSet: zoneSet, restingHR: restingHR))
        // Resting at or above max leaves no reserve to measure against.
        XCTAssertNil(EffortFeasibility.sessionEffortRange(zone: 2, minutes: 30, zoneSet: zoneSet, restingHR: 200))
    }

    /// Unlike `StrainScorer.strain`, a hypothetical shorter than ten minutes still gets an honest
    /// answer — that floor guards against trusting a thin REAL stream and has no bearing on arithmetic.
    func testShortSessionsStillGetAnAnswer() throws {
        let range = try XCTUnwrap(
            EffortFeasibility.sessionEffortRange(zone: 4, minutes: 5, zoneSet: zoneSet, restingHR: restingHR))
        XCTAssertGreaterThan(range.high, 0)
    }

    func testSentenceReadsAsARange() throws {
        let range = try XCTUnwrap(
            EffortFeasibility.sessionEffortRange(zone: 2, minutes: 20, zoneSet: zoneSet, restingHR: restingHR))
        let sentence = EffortFeasibility.sentence(zone: 2, minutes: 20, range: range)
        XCTAssertTrue(sentence.contains("20 min"), sentence)
        XCTAssertTrue(sentence.contains("Zone 2"), sentence)
        XCTAssertTrue(sentence.contains("Effort"), sentence)
    }
}
