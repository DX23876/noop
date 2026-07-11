import XCTest
@testable import OuraProtocol

/// Tests for the MET-stream activity estimate (OuraActivityEstimator). All inputs are synthetic MET
/// series; the point is the arithmetic (MET-minutes / active-minutes / energy), the epochSeconds
/// scaling, and the honest edge cases (empty input, no body mass).
final class ActivityEstimateTests: XCTestCase {

    func testEmptyInputYieldsZeroEstimateNotNil() {
        let e = OuraActivityEstimator.estimate(metSamples: [], epochSeconds: 60)
        XCTAssertEqual(e.sampleCount, 0)
        XCTAssertEqual(e.meanMET, 0)
        XCTAssertEqual(e.maxMET, 0)
        XCTAssertEqual(e.metMinutes, 0)
        XCTAssertEqual(e.activeMinutes, 0)
        XCTAssertNil(e.estActiveKcal, "no body mass -> no energy")
    }

    func testMeanMaxAndMetMinutesAt60s() {
        // 4 samples at 60s each = 4 minutes total. Sum = 8.0 MET.
        let e = OuraActivityEstimator.estimate(metSamples: [1.0, 1.0, 3.0, 3.0], epochSeconds: 60)
        XCTAssertEqual(e.sampleCount, 4)
        XCTAssertEqual(e.meanMET, 2.0)                 // 8/4
        XCTAssertEqual(e.maxMET, 3.0)
        XCTAssertEqual(e.metMinutes, 8.0)              // 8.0 MET * 1 min/sample
        XCTAssertEqual(e.activeMinutes, 2.0)           // two samples >= 3.0 MET, 1 min each
    }

    func testActiveMinutesRespectsThresholdAndEpoch() {
        // 30s epochs (0.5 min each); threshold default 3.0. Three samples >= 3.0 -> 1.5 active minutes.
        let e = OuraActivityEstimator.estimate(metSamples: [2.9, 3.0, 4.0, 5.0], epochSeconds: 30)
        XCTAssertEqual(e.activeMinutes, 1.5, "3 samples at/above 3.0 MET * 0.5 min")
        XCTAssertEqual(e.metMinutes, (2.9 + 3.0 + 4.0 + 5.0) * 0.5, accuracy: 0.001)
    }

    func testActiveEnergySubtractsBasalTotalDoesNot() {
        // 2 samples of 2.0 MET, 60s each, 70 kg. epochHours = 1/60.
        // active (above-resting) = (2-1)+(2-1) = 2.0 MET-epochs; total = 4.0 MET-epochs.
        let e = OuraActivityEstimator.estimate(metSamples: [2.0, 2.0], epochSeconds: 60, bodyMassKg: 70)
        let epochHours = 60.0 / 3600.0
        XCTAssertEqual(e.estActiveKcal!, 2.0 * 70 * epochHours, accuracy: 0.01)
        XCTAssertEqual(e.estTotalKcal!, 4.0 * 70 * epochHours, accuracy: 0.01)
        XCTAssertGreaterThan(e.estTotalKcal!, e.estActiveKcal!)
    }

    func testSubRestingSampleNeverContributesNegativeActiveEnergy() {
        // 0.5 MET (below the 1-MET floor) must clamp to 0 active energy, not go negative.
        let e = OuraActivityEstimator.estimate(metSamples: [0.5], epochSeconds: 60, bodyMassKg: 80)
        XCTAssertEqual(e.estActiveKcal!, 0.0, "below-resting clamps to 0 above-resting energy")
        XCTAssertGreaterThan(e.estTotalKcal!, 0.0, "but it still counts toward gross energy")
    }

    func testEpochSecondsScalesMinutesAndEnergyLinearly() {
        let samples = [1.5, 4.0, 4.0]
        let e60 = OuraActivityEstimator.estimate(metSamples: samples, epochSeconds: 60, bodyMassKg: 75)
        let e120 = OuraActivityEstimator.estimate(metSamples: samples, epochSeconds: 120, bodyMassKg: 75)
        // Doubling the epoch doubles minutes and energy, but not the cadence-independent means.
        XCTAssertEqual(e120.metMinutes, e60.metMinutes * 2, accuracy: 0.02)
        XCTAssertEqual(e120.activeMinutes, e60.activeMinutes * 2, accuracy: 0.02)
        // Doubling a 2-dp-rounded value can differ from the directly-computed 2-dp value by a cent.
        XCTAssertEqual(e120.estActiveKcal!, e60.estActiveKcal! * 2, accuracy: 0.02)
        XCTAssertEqual(e120.meanMET, e60.meanMET)
        XCTAssertEqual(e120.maxMET, e60.maxMET)
    }

    func testEstimateFromDecodedRecordsFlattensMET() {
        // Two 0x50 records with distinct MET series flatten to one 4-sample aggregate.
        let recs = [
            OuraActivityInfo(ringTimestamp: 1, state: 0, met: [1.0, 1.0]),
            OuraActivityInfo(ringTimestamp: 2, state: 88, met: [4.0, 6.0]),
        ]
        let e = OuraActivityEstimator.estimate(from: recs, epochSeconds: 60)
        XCTAssertEqual(e.sampleCount, 4)
        XCTAssertEqual(e.maxMET, 6.0)
        XCTAssertEqual(e.meanMET, 3.0)                 // (1+1+4+6)/4
        XCTAssertEqual(e.activeMinutes, 2.0)           // 4.0 and 6.0 clear 3.0 MET
    }

    func testGoldenEndToEndFromRealisticSample() {
        // A resting-through-light minute: 13 samples at 60s, one 0x50 record's worth.
        let met = [1.2, 0.9, 0.9, 0.9, 1.0, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 1.2]
        let e = OuraActivityEstimator.estimate(metSamples: met, epochSeconds: 60, bodyMassKg: 70)
        XCTAssertEqual(e.sampleCount, 13)
        XCTAssertEqual(e.activeMinutes, 0.0, "nothing reaches 3.0 MET — honest zero active minutes")
        XCTAssertEqual(e.meanMET, 0.95)                // 12.4 sum / 13, rounded
        XCTAssertGreaterThan(e.estTotalKcal!, 0)
        // above-resting = (0.2 + 0.2) MET-epochs * 70 kg / 60 h -> ~0.47 kcal
        XCTAssertEqual(e.estActiveKcal!, 0.47, accuracy: 0.01)
    }
}
