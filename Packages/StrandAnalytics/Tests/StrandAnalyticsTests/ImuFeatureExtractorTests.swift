import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Pins `ImuFeatureExtractor` — activity features from decoded 5/MG raw IMU (#423). Per the repo's
/// derived-signal rule, cadence is validated to recover MULTIPLE distinct injected rates (not one lucky
/// match), and the still/energy/gyro cases are checked independently.
final class ImuFeatureExtractorTests: XCTestCase {

    /// 100 Hz samples: gravity on Z + a sinusoidal wobble of amplitude `amp` g at `cadence` Hz on Z,
    /// and an optional constant gyro rotation `gyroDps` on gx.
    private func gaitSamples(cadence: Double, amp: Double = 0.2, seconds: Double = 6,
                             gyroDps: Double = 0) -> [RawImuSample] {
        let rate = 100.0, n = Int(seconds * rate)
        return (0..<n).map { i in
            let az = 1.0 + amp * sin(2 * .pi * cadence * Double(i) / rate)
            return RawImuSample(ax: 0, ay: 0, az: az, gx: gyroDps, gy: 0, gz: 0)
        }
    }

    func testRecoversMultipleDistinctCadences() {
        // The load-bearing test: the extractor must track a VARYING input, not manufacture one rate.
        for target in [1.4, 1.8, 2.4, 3.0] {
            let f = ImuFeatureExtractor.extract(gaitSamples(cadence: target), sampleRateHz: 100)
            XCTAssertNotNil(f.cadenceHz, "cadence \(target) Hz should be detected")
            XCTAssertEqual(f.cadenceHz ?? -9, target, accuracy: 0.15,
                           "recovered cadence should match the injected \(target) Hz")
            XCTAssertGreaterThan(f.cadenceStrength, 0.4, "a clean sinusoid should read as strongly rhythmic")
        }
    }

    func testStillHasNoCadenceAndLowEnergy() {
        // Gravity only, negligible noise.
        let still = (0..<600).map { _ in RawImuSample(ax: 0, ay: 0, az: 1.0, gx: 0, gy: 0, gz: 0) }
        let f = ImuFeatureExtractor.extract(still, sampleRateHz: 100)
        XCTAssertNil(f.cadenceHz, "a still wrist has no gait cadence")
        XCTAssertLessThan(f.accelEnergyG, 0.01)
        XCTAssertLessThan(f.gyroEnergyDps, 0.01)
    }

    func testEnergyAndJerkRiseWithMotion() {
        let still = ImuFeatureExtractor.extract(gaitSamples(cadence: 2.0, amp: 0.0), sampleRateHz: 100)
        let moving = ImuFeatureExtractor.extract(gaitSamples(cadence: 2.0, amp: 0.3), sampleRateHz: 100)
        XCTAssertGreaterThan(moving.accelEnergyG, still.accelEnergyG + 0.05)
        XCTAssertGreaterThan(moving.jerkRms, still.jerkRms)
    }

    func testGyroEnergyReflectsRotation() {
        let f = ImuFeatureExtractor.extract(gaitSamples(cadence: 2.0, gyroDps: 45), sampleRateHz: 100)
        XCTAssertEqual(f.gyroEnergyDps, 45, accuracy: 1.0, "constant 45 dps rotation should read back")
    }

    func testExtractFromDecodedFrames() {
        // End-to-end from the WhoopProtocol decoder: two frames concatenate into one feature window.
        let frame = Whoop5ImuFrame(baseTs: 0, sampleRateHz: 100, samples: gaitSamples(cadence: 2.2))
        let f = ImuFeatureExtractor.extract(frames: [frame, frame])
        XCTAssertEqual(f.sampleCount, frame.samples.count * 2)
        XCTAssertEqual(f.cadenceHz ?? -9, 2.2, accuracy: 0.15)
    }
}
