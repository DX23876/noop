import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Fork (DX23876): the nap detector moved from Android's Kotlin into the core keeps its tri-state verdict.
final class NapDetectorTests: XCTestCase {
    private let on = NapDetector.Config(enabled: true)

    /// A still wrist every 30 s for `minutes`, starting at `t0`.
    private func still(_ t0: Int, minutes: Int) -> [GravitySample] {
        (0..<(minutes * 2)).map { GravitySample(ts: t0 + $0 * 30, x: 0, y: 0, z: 1) }
    }

    func testAQuietSettledStretchIsANap() {
        let g = still(1_000, minutes: 40)
        let hr = (0..<80).map { HRSample(ts: 1_000 + $0 * 30, bpm: 52) }
        let d = NapDetector.evaluate(gravity: g, hr: hr, restingHr: 55, config: on)
        XCTAssertEqual(d.verdict, .nap)
        XCTAssertEqual(d.candidate?.meanHr, 52)
        XCTAssertGreaterThan(d.candidate?.confidence ?? 0, 0.4)
    }

    func testAnElevatedHeartRateMeansAwake() {
        let g = still(1_000, minutes: 40)
        let hr = (0..<80).map { HRSample(ts: 1_000 + $0 * 30, bpm: 80) }
        XCTAssertEqual(NapDetector.evaluate(gravity: g, hr: hr, restingHr: 55, config: on).verdict, .none)
    }

    func testTooShortIsNoneTooLongIsInconclusiveAndSparseCannotTell() {
        XCTAssertEqual(NapDetector.evaluate(gravity: still(0, minutes: 12), hr: [], restingHr: nil, config: on).verdict, .none)
        XCTAssertEqual(NapDetector.evaluate(gravity: still(0, minutes: 120), hr: [], restingHr: nil, config: on).verdict,
                       .inconclusive)
        let sparse = (0..<25).map { GravitySample(ts: $0 * 600, x: 0, y: 0, z: 1) }
        XCTAssertEqual(NapDetector.evaluate(gravity: sparse, hr: [], restingHr: nil, config: on).verdict, .inconclusive)
        XCTAssertEqual(NapDetector.evaluate(gravity: still(0, minutes: 40), hr: [], restingHr: nil,
                                            config: NapDetector.Config()).verdict, .inconclusive)
    }

    func testAnUnknownRestingBandCapsTheConfidence() {
        let d = NapDetector.evaluate(gravity: still(0, minutes: 90), hr: [], restingHr: nil, config: on)
        XCTAssertEqual(d.verdict, .nap)
        XCTAssertEqual(d.candidate?.confidence ?? 1, 0.7, accuracy: 1e-9)
    }
}
