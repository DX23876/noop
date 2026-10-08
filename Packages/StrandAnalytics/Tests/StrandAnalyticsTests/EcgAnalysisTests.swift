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
        // A Gaussian T wave has no sharp end. The trapezium method puts it between 2 and 3 sigma past the
        // peak (the tangent method stops at exactly 2); the annotated QT Database is what fixed the method.
        let tEnd = try XCTUnwrap(f.tEndMs)
        XCTAssertGreaterThanOrEqual(tEnd, 335)                            // 260 + 2 x 40, less a sample
        XCTAssertLessThanOrEqual(tEnd, 385)                               // 260 + 3 x 40, plus a sample
        // A Gaussian P wave has no sharp start either; the wavelet delineator puts it 2 to 3 sigma early.
        let pOnset = try XCTUnwrap(f.pOnsetMs)
        XCTAssertLessThanOrEqual(pOnset, -195)                            // -160 - 2 x 20, plus a sample
        XCTAssertGreaterThanOrEqual(pOnset, -225)                         // -160 - 3 x 20, less a sample
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

    func testLargeImpulsesDoNotReplaceTheRhythm() throws {
        var samples = strip(rTimesMs: regular(rrMs: 800))
        for index in [500, 1000, 1500, 2000] { samples[index] = 30_000 }
        let result = try XCTUnwrap(EcgAnalysis.analyze(samples))
        XCTAssertEqual(result.meanHeartRate, 75, accuracy: 2)
    }

    func testMonophasicComplexHasSymmetricBoundaries() throws {
        let z = (0..<91).map { index -> Double in
            let t = Double(index - 35) * 10
            return (900 * exp(-t * t / (2 * 20 * 20))).rounded()
        }
        let f = try XCTUnwrap(EcgAnalysis.locateFiducials(z, rIndex: 35, fs: 100, meanRRms: 1000))
        XCTAssertEqual(f.jPointMs, -f.qrsOnsetMs, accuracy: 10)
    }

    func testTEndDoesNotUseTheNextQRS() throws {
        let z = (0..<91).map { index -> Double in
            let t = Double(index - 35) * 10
            func g(_ center: Double, _ sigma: Double, _ amplitude: Double) -> Double {
                amplitude * exp(-pow(t - center, 2) / (2 * sigma * sigma))
            }
            return g(0, 10, 900) + g(30, 8, -220) + g(260, 40, 260) + g(400, 10, 900)
        }
        let f = try XCTUnwrap(EcgAnalysis.locateFiducials(z, rIndex: 35, fs: 100, meanRRms: 400))
        XCTAssertEqual(try XCTUnwrap(f.tEndMs), 340, accuracy: 15)
    }

    func testIrregularRhythmStillReportsRateAndIrregularity() throws {
        var seed: UInt64 = 99
        var times: [Double] = []
        var t = 400.0
        var intervals: [Double] = []
        while t < 29_000 {
            times.append(t)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let rr = 450 + Double(seed >> 54) / 1023 * 650          // 450 to 1100 ms, no pattern
            intervals.append(rr)
            t += rr
        }
        var beat = Beat()
        beat.p.microvolts = 0                                       // no P waves, as in atrial fibrillation
        let result = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: times, beat: beat)))
        let expected = 60_000 / (intervals.dropLast().reduce(0, +) / Double(intervals.count - 1))
        XCTAssertEqual(result.meanHeartRate, expected, accuracy: 3)
        XCTAssertGreaterThan(result.irregularBeats, 5)
        XCTAssertNil(result.prMs)
    }

    func testAlternatingShortLongRhythmStillReportsRate() throws {
        // Every interval is 40 % off its neighbours' median, so every beat is irregular by timing, yet
        // every QRS has the same shape (an early beat of normal shape, as in atrial bigeminy).
        var times: [Double] = []
        var t = 400.0
        var short = true
        while t < 29_000 { times.append(t); t += short ? 500 : 1100; short.toggle() }
        let result = try XCTUnwrap(EcgAnalysis.analyze(strip(rTimesMs: times)))
        XCTAssertEqual(result.meanHeartRate, 75, accuracy: 2)
        XCTAssertGreaterThan(result.irregularBeats, 10)
    }

    /// The strap's stream as a first-order high-pass of the true strip.
    func highPassed(_ samples: [Int16?], cutoffHz: Double) -> [Int16?] {
        let a = 1 / (1 + 2 * Double.pi * cutoffHz / 100)
        var y = 0.0, previous = Double(samples[0] ?? 0)
        return samples.map { sample in
            let x = Double(sample ?? 0)
            y = a * (y + x - previous)
            previous = x
            return Int16(clamping: Int(y.rounded()))
        }
    }

    func testUndoingTheStrapHighPassRecoversTheIntervals() throws {
        let truth = strip(rTimesMs: regular(rrMs: 860))
        let filtered = highPassed(truth, cutoffHz: EcgAnalysis.strapHighPassHz)
        let reference = try XCTUnwrap(EcgAnalysis.analyze(truth))
        let compensated = try XCTUnwrap(EcgAnalysis.analyze(
            filtered, compensatingHighPassHz: EcgAnalysis.strapHighPassHz))
        XCTAssertEqual(try XCTUnwrap(compensated.qrsMs), try XCTUnwrap(reference.qrsMs), accuracy: 10)
        XCTAssertEqual(try XCTUnwrap(compensated.qtMs), try XCTUnwrap(reference.qtMs), accuracy: 15)
        XCTAssertEqual(compensated.meanHeartRate, reference.meanHeartRate, accuracy: 0.5)
        // And the filter is what distorts: without the inverse the T wave shrinks by a quarter or more.
        let raw = try XCTUnwrap(EcgAnalysis.analyze(filtered))
        let tPeak = { (r: EcgAnalysis.Result) -> Double in
            let i = r.templateRIndex + Int((r.fiducials?.tPeakMs ?? 260) / 10)
            return r.template[i]
        }
        XCTAssertLessThan(tPeak(raw), 0.8 * tPeak(reference))
        XCTAssertGreaterThan(tPeak(compensated), 0.85 * tPeak(reference))
    }

    func testNoiseBurstsOnANoisyStripAreNotCountedAsBeats() throws {
        // Muscle tremor on the clasp: broadband noise of a quarter of the R height, plus short bursts
        // between beats that peak at about 30 % of an R wave (the false beats seen on a real MG strip).
        var samples = strip(rTimesMs: regular(rrMs: 960), noise: 200)
        var seed: UInt64 = 5
        for beatMs in regular(rrMs: 960).dropLast() where Int(beatMs) % 3 == 1 {
            let at = Int((beatMs + 480) / 10)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            for k in 0..<4 { samples[at + k] = Int16(clamping: Int(samples[at + k]!) + (k % 2 == 0 ? 280 : -260)) }
        }
        let result = try XCTUnwrap(EcgAnalysis.analyze(samples))
        XCTAssertEqual(result.meanHeartRate, 62.5, accuracy: 1.5)
        XCTAssertLessThanOrEqual(result.irregularBeats, 1)
    }

    func testNoiseAloneDoesNotProduceRhythm() {
        var seed: UInt64 = 17
        let samples: [Int16?] = (0..<3000).map { _ in
            seed = seed &* 6364136223846793005 &+ 1
            return Int16(Int(seed >> 48) - 32768)
        }
        XCTAssertNil(EcgAnalysis.analyze(samples))
    }

    func testRatesAndPolarityAcrossSupportedRange() throws {
        for bpm in [35.0, 50, 75, 100, 150, 180] {
            var beat = Beat()
            // Compress P/T timing at high rates so adjacent cycles do not overlap.
            let scale = min(1, 75 / bpm)
            beat.p.centerMs *= scale
            beat.p.sigmaMs *= scale
            beat.t.centerMs *= scale
            beat.t.sigmaMs *= scale
            for sign in [-1.0, 1.0] {
                let a = try XCTUnwrap(EcgAnalysis.analyze(strip(
                    rTimesMs: regular(rrMs: 60_000 / bpm), beat: beat, sign: sign)))
                XCTAssertEqual(a.meanHeartRate, bpm, accuracy: 2, "bpm=\(bpm), sign=\(sign)")
            }
        }
    }
}

final class EcgResampleTests: XCTestCase {
    func testSlowSignalSurvivesAndLengthMatchesDuration() {
        let rate = 512.0
        let source: [Double] = (0..<5120).map { (k: Int) -> Double in
            500 * sin(2 * Double.pi * 5 * Double(k) / rate)
        }
        let out = EcgResample.toHundredHertz(source, rate: rate)
        XCTAssertEqual(out.count, 1000, accuracy: 1)
        for k in stride(from: 10, to: 990, by: 37) {
            let expected = 500 * sin(2 * Double.pi * 5 * Double(k) / 100)
            XCTAssertEqual(Double(out[k]!), expected, accuracy: 25, "k=\(k)")   // the 5-tap mean costs ~2 %
        }
    }

    func testHighFrequencyNoiseIsDamped() {
        let rate = 512.0
        let source: [Double] = (0..<5120).map { (k: Int) -> Double in
            300 * sin(2 * Double.pi * 102.4 * Double(k) / rate)
        }
        let out = EcgResample.toHundredHertz(source, rate: rate).compactMap { $0 }.dropFirst(2).dropLast(2)   // edges average a partial window
        XCTAssertLessThan(out.map { abs(Double($0)) }.max() ?? 0, 30)
    }

    func testAResampledReferenceStripMeasuresLikeANativeOne() throws {
        let rate = 512.0
        let native = EcgAnalysisTests().strip(rTimesMs: EcgAnalysisTests().regular(rrMs: 800))
        let fine = (0..<Int(30 * rate)).map { k -> Double in
            let tMs = Double(k) / rate * 1000
            let i = min(Int(tMs / 10), native.count - 2)
            let f = tMs / 10 - Double(i)
            return Double(native[i]!) + (Double(native[i + 1]!) - Double(native[i]!)) * f
        }
        let a = try XCTUnwrap(EcgAnalysis.analyze(native))
        let b = try XCTUnwrap(EcgAnalysis.analyze(EcgResample.toHundredHertz(fine, rate: rate)))
        XCTAssertEqual(a.meanHeartRate, b.meanHeartRate, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(a.qtMs), try XCTUnwrap(b.qtMs), accuracy: 10)
    }
}

/// `WaveletDelineator` against the Python prototype it was ported from (martinez_lin.py, the session's
/// reference implementation of Martinez et al. 2004). The expected values are that prototype's stdout for
/// the same synthetic median beats; the port matched it on all 211 QT Database median beats as well.
final class WaveletDelineatorOracleTests: XCTestCase {
    /// A median beat at 100 Hz, R at index 35, 91 samples, from Gaussian waves (centre ms, sigma ms, µV).
    func beat(_ waves: [(Double, Double, Double)]) -> [Double] {
        (0..<91).map { i in
            let t = Double(i - 35) * 10
            let v = waves.reduce(0.0) { $0 + $1.2 * exp(-(t - $1.0) * (t - $1.0) / (2 * $1.1 * $1.1)) }
            return (v * 10).rounded() / 10
        }
    }

    let base: [(Double, Double, Double)] = [(-160, 20, 90), (-28, 8, -90), (0, 10, 900), (28, 8, -220), (260, 40, 260)]

    func check(_ waves: [(Double, Double, Double)], rr: Double, pOnset: Double, qrsOnset: Double,
               line: UInt = #line) throws {
        let r = try XCTUnwrap(WaveletDelineator.pWave(beat(waves), rIndex: 35, meanRRms: rr), line: line)
        XCTAssertEqual(r.pOnsetMs, pOnset, accuracy: 0.01, line: line)
        XCTAssertEqual(r.qrsOnsetMs, qrsOnset, accuracy: 0.01, line: line)
    }

    func testMatchesThePrototype() throws {
        try check(base, rr: 800, pOnset: -216, qrsOnset: -32)
        try check([(-220, 20, 90)] + base.dropFirst(), rr: 1000, pOnset: -276, qrsOnset: -32)
        try check(base.map { ($0.0, $0.1, -$0.2) }, rr: 800, pOnset: -216, qrsOnset: -32)
        try check([(-120, 15, 80)] + base[1...3] + [(200, 30, 240)], rr: 500, pOnset: -168, qrsOnset: -32)
    }
}
