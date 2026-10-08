import XCTest
@testable import StrandAnalytics

/// `EcgAnalysis` against synthetic single-lead strips whose waves are Gaussians with known timing. The
/// tangent method puts a Gaussian wave's end (or onset) at its centre plus (minus) two sigma, which gives
/// exact ground truth for T end and P onset. Each interval is checked to TRACK an injected change, not
/// only to land once on a plausible number (CLAUDE.md: validate against a varying input).
final class EcgAnalysisTests: XCTestCase {

    struct Wave { var centerMs: Double; var sigmaMs: Double; var microvolts: Double }

    struct Beat {
        var p = Wave(centerMs: -160, sigmaMs: 20, microvolts: 90)
        var q = Wave(centerMs: -28, sigmaMs: 8, microvolts: -90)
        var r = Wave(centerMs: 0, sigmaMs: 10, microvolts: 900)
        var s = Wave(centerMs: 28, sigmaMs: 8, microvolts: -220)
        var t = Wave(centerMs: 260, sigmaMs: 40, microvolts: 260)
        var waves: [Wave] { [p, q, r, s, t] }
    }

    /// A strip at 100 Hz: beats at the given R times, small deterministic noise, optional gap and sign.
    func strip(seconds: Double = 30, rTimesMs: [Double], beat: Beat = Beat(), noise: Double = 12,
               sign: Double = 1, gap: Range<Int>? = nil) -> [Int16?] {
        let count = Int(seconds * 100)
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31) - 0.5
        }
        return (0..<count).map { k -> Int16? in
            if let gap, gap.contains(k) { return nil }
            let tMs = Double(k) * 10
            var v = 0.0
            for r in rTimesMs where abs(tMs - r) < 700 {
                for w in beat.waves {
                    let d = tMs - (r + w.centerMs)
                    v += w.microvolts * exp(-d * d / (2 * w.sigmaMs * w.sigmaMs))
                }
            }
            v += noise * random() + 40 * sin(2 * Double.pi * 0.3 * tMs / 1000)   // noise and breathing wander
            return Int16(clamping: Int((sign * v).rounded()))
        }
    }

    func regular(rrMs: Double, seconds: Double = 30) -> [Double] {
        Array(stride(from: 400.0, to: seconds * 1000 - 600, by: rrMs))
    }

    func testHeartRateAndIntervalsOnARegularStrip() throws {
        let result = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: regular(rrMs: 800))))
        XCTAssertEqual(result.meanHeartRate, 75, accuracy: 0.5)
        XCTAssertEqual(result.irregularBeats, 0)
        XCTAssertFalse(result.inverted)
        XCTAssertGreaterThanOrEqual(result.beatsAveraged, 30)
        let f = try XCTUnwrap(result.fiducials)
        XCTAssertEqual(try XCTUnwrap(f.tEndMs), 340, accuracy: 12)        // 260 + 2 x 40
        XCTAssertEqual(try XCTUnwrap(f.pOnsetMs), -200, accuracy: 12)     // -160 - 2 x 20
        let qrs = try XCTUnwrap(result.qrsMs)
        XCTAssertTrue((60...110).contains(qrs), "QRS \(qrs)")
        let qt = try XCTUnwrap(result.qtMs)
        XCTAssertEqual(try XCTUnwrap(result.qtcFridericiaMs), qt / pow(0.8, 1.0 / 3.0), accuracy: 0.5)
    }

    func testQTTracksAnInjectedChange() throws {
        var long = Beat()
        long.t.centerMs = 320
        let base = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: regular(rrMs: 900)))?.qtMs)
        let longer = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: regular(rrMs: 900), beat: long))?.qtMs)
        XCTAssertEqual(longer - base, 60, accuracy: 10)
    }

    func testPRTracksAnInjectedChange() throws {
        var long = Beat()
        long.p.centerMs = -220
        let base = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: regular(rrMs: 900)))?.prMs)
        let longer = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: regular(rrMs: 900), beat: long))?.prMs)
        XCTAssertEqual(longer - base, 60, accuracy: 10)
    }

    func testQRSWidensWithAWiderComplex() throws {
        var wide = Beat()
        wide.r.sigmaMs = 18
        wide.q.centerMs = -48
        wide.s.centerMs = 48
        let base = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: regular(rrMs: 900)))?.qrsMs)
        let wider = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: regular(rrMs: 900), beat: wide))?.qrsMs)
        XCTAssertGreaterThan(wider - base, 25)
    }

    func testInvertedLeadMeasuresTheSame() throws {
        let upright = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: regular(rrMs: 800))))
        let inverted = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: regular(rrMs: 800), sign: -1)))
        XCTAssertTrue(inverted.inverted)
        XCTAssertEqual(inverted.meanHeartRate, upright.meanHeartRate, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(inverted.qtMs), try XCTUnwrap(upright.qtMs), accuracy: 10)
    }

    func testPrematureBeatIsCountedAndKeptOutOfHRV() throws {
        var times = regular(rrMs: 800)
        times[15] -= 300                                   // one beat 300 ms early
        let result = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: times)))
        XCTAssertGreaterThanOrEqual(result.irregularBeats, 1)
        XCTAssertLessThan(try XCTUnwrap(result.rmssdMs), 15)  // the steady rhythm around it
        XCTAssertNotNil(result.qtMs)
    }

    func testRMSSDOfAnAlternatingRhythm() throws {
        var times: [Double] = []
        var t = 400.0
        var flip = false
        while t < 29_000 { times.append(t); t += flip ? 860 : 800; flip.toggle() }
        let result = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: times)))
        XCTAssertEqual(try XCTUnwrap(result.rmssdMs), 60, accuracy: 6)
        XCTAssertEqual(result.irregularBeats, 0)
    }

    func testLostPacketDoesNotBridgeAnInterval() throws {
        let result = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: regular(rrMs: 800), gap: 1400..<1500)))
        XCTAssertEqual(result.irregularBeats, 0)
        XCTAssertEqual(result.meanHeartRate, 75, accuracy: 0.5)
    }

    func testFlatOrTooShortStripReportsNothing() {
        XCTAssertNil(EcgAnalysis.analyze([Int16?](repeating: 0, count: 3000)))
        XCTAssertNil(EcgAnalysis.analyze([1, 2, 3]))
    }
}
