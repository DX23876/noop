import XCTest
@testable import WhoopProtocol

/// PPG-derived per-second HR from the WHOOP 5.0 v26 optical buffer (issue #156).
///
/// The estimator is windowed autocorrelation of the detrended 24 Hz waveform. These tests drive it with
/// SYNTHETIC signals (a clean pulse → known HR; white noise → nothing) so they are deterministic and
/// need no capture fixtures, plus the Streams decode-tolerance check for the new `ppg_hr` key.
final class PpgHrTests: XCTestCase {
    private let fs = PpgHr.sampleRateHz   // 24

    /// One second (`fs` samples) of a `bpm`-Hz sine, ADC-count amplitude, at sample-phase offset
    /// `startSample` so consecutive seconds form a continuous waveform.
    private func sineSecond(bpm: Double, startSample: Int, amp: Double = 1000) -> [Int] {
        let f = bpm / 60.0
        return (0..<fs).map { i in
            Int(amp * sin(2 * Double.pi * f * Double(startSample + i) / Double(fs)))
        }
    }

    /// 30 consecutive 1 s records of a clean `bpm` pulse, ts starting at `base`.
    private func sineRecords(bpm: Double, seconds: Int = 30, base: Int = 1_780_000_000)
        -> [(ts: Int, samples: [Int])] {
        (0..<seconds).map { s in
            (ts: base + s, samples: sineSecond(bpm: bpm, startSample: s * fs))
        }
    }

    func testEstimateRecoversKnownHr() throws {
        // 8 s window of a clean 70 bpm pulse → ~70 bpm at high confidence.
        var sig = [Int]()
        for s in 0..<8 { sig.append(contentsOf: sineSecond(bpm: 70, startSample: s * fs)) }
        let est = try XCTUnwrap(PpgHr.estimate(sig))
        XCTAssertEqual(est.bpm, 70, accuracy: 2.0)
        XCTAssertGreaterThan(est.conf, 0.5)
    }

    func testDeriveSineSeriesIsAround70() {
        let series = PpgHr.derivePpgHr(records: sineRecords(bpm: 70))
        XCTAssertFalse(series.isEmpty)
        // Every second's estimate lands at 70±2 with confidence over 0.5.
        for s in series {
            XCTAssertEqual(s.bpm, 70, accuracy: 2)
            XCTAssertGreaterThan(s.conf, 0.5)
        }
        // Ascending, one per estimable second.
        XCTAssertEqual(series.map(\.ts), series.map(\.ts).sorted())
    }

    func testWhiteNoiseProducesNoEstimates() {
        // Deterministic LCG so the test never flakes — a flat, non-pulsatile signal must not yield HR.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(Int32(truncatingIfNeeded: state >> 33)) % 1000
        }
        let records: [(ts: Int, samples: [Int])] = (0..<30).map { s in
            (ts: 1_780_000_000 + s, samples: (0..<fs).map { _ in next() })
        }
        let series = PpgHr.derivePpgHr(records: records)
        XCTAssertTrue(series.isEmpty, "white noise must not fabricate an HR (got \(series.count))")
    }

    func testEstimateRejectsTooShortWindow() {
        // < 3 s of samples → nil (can't resolve a low HR).
        XCTAssertNil(PpgHr.estimate(sineSecond(bpm: 70, startSample: 0)))   // 1 s only
    }

    func testGapBreaksRunsButBothSidesEstimate() {
        // Two 5 s runs of 60 bpm separated by a 100 s gap — both runs produce estimates, the gap none.
        var recs = sineRecords(bpm: 60, seconds: 5, base: 1_780_000_000)
        recs += sineRecords(bpm: 60, seconds: 5, base: 1_780_000_200)
        let series = PpgHr.derivePpgHr(records: recs)
        XCTAssertFalse(series.isEmpty)
        XCTAssertTrue(series.allSatisfy { abs($0.bpm - 60) <= 2 })
        // No estimate lands inside the gap.
        XCTAssertFalse(series.contains { $0.ts > 1_780_000_005 && $0.ts < 1_780_000_200 })
    }

    func testLowHrWithRecordRateArtifactDoesNotSnapTo60() {
        // A true ~50 bpm pulse PLUS a per-record sawtooth that resets every `fs` samples — the
        // record-rate artifact ryanbr flagged (#194). The sawtooth autocorrelates at lag = fs (60 bpm)
        // and is DISCONTINUOUS at record boundaries; without the boundary-gated notch the estimator
        // would snap a sleeping HR to 60. It must recover ~50.
        let f = 50.0 / 60.0
        var sig = [Int]()
        for s in 0..<10 {
            for i in 0..<fs {
                let pulse = 1000.0 * sin(2 * Double.pi * f * Double(s * fs + i) / Double(fs))
                let sawtooth = 25.0 * Double(i)   // 0…575 within a record, drops at the boundary
                sig.append(Int(pulse + sawtooth))
            }
        }
        let est = PpgHr.estimate(sig)
        XCTAssertNotNil(est, "a real low-HR pulse under a record-rate artifact must still estimate")
        if let est {
            XCTAssertEqual(est.bpm, 50, accuracy: 4.0,
                           "estimate snapped to \(est.bpm) — the record-rate artifact wasn't removed")
        }
    }

    func testTrue60BpmIsPreservedNotNotchedAway() {
        // A clean 60 bpm pulse is ALSO period-fs, but flows smoothly across record boundaries — the
        // boundary gate must NOT treat it as the artifact and erase it.
        var sig = [Int]()
        for s in 0..<8 { sig.append(contentsOf: sineSecond(bpm: 60, startSample: s * fs)) }
        let est = PpgHr.estimate(sig)
        XCTAssertNotNil(est)
        if let est { XCTAssertEqual(est.bpm, 60, accuracy: 2.0) }
    }

    func testSubLagInterpolationRecoversHrsThatIntegerLagQuantizes() throws {
        // Derived-biosignal standard (CLAUDE.md): recover MULTIPLE injected values, not one. Each true HR
        // here sits BETWEEN integer autocorrelation lags at 24 Hz (period = 1440/bpm samples), so the nearest
        // integer lag is > 2 bpm off and the default integer-lag estimator quantizes AWAY from the truth,
        // while the opt-in parabolic sub-lag interpolation (Variant A) refines the ACF peak and recovers it
        // within +-2 bpm. Twin of the Kotlin PpgHrTest case. (Exact-integer-lag rates 120/160/180 are avoided.)
        for trueBpm in [137.0, 150.0, 163.0, 170.0] {
            var sig = [Int]()
            for s in 0..<16 { sig.append(contentsOf: sineSecond(bpm: trueBpm, startSample: s * fs)) }

            // Default OFF = byte-identical to today: integer-lag quantization, not within +-2 of the truth.
            let off = try XCTUnwrap(PpgHr.estimate(sig))
            XCTAssertGreaterThan(abs(off.bpm - trueBpm), 2,
                                 "default path should quantize away from \(trueBpm) (got \(off.bpm))")

            // Variant ON: parabolic sub-lag interpolation lands within +-2 bpm of the true rate.
            let on = try XCTUnwrap(PpgHr.estimate(sig, subLagInterp: true))
            XCTAssertEqual(on.bpm, trueBpm, accuracy: 2.0,
                           "sub-lag interp should recover \(trueBpm)+-2 (got \(on.bpm))")
        }
    }

    /// Streams decode tolerance: a JSON missing `ppg_hr` still decodes (defaults to empty), and a
    /// present `ppg_hr` round-trips. Mirrors the decodeIfPresent guard for the other biometric keys.
    func testStreamsDecodeToleratesMissingAndPresentPpgHr() throws {
        let dec = JSONDecoder()
        // Missing key → empty.
        let s1 = try dec.decode(Streams.self, from: Data(#"{"hr":[]}"#.utf8))
        XCTAssertTrue(s1.ppgHr.isEmpty)
        // Present key → decoded under the snake_case CodingKey.
        let json = #"{"ppg_hr":[{"ts":1780000000,"bpm":70.0,"conf":0.91}]}"#
        let s2 = try dec.decode(Streams.self, from: Data(json.utf8))
        XCTAssertEqual(s2.ppgHr, [PpgHrSample(ts: 1_780_000_000, bpm: 70, conf: 0.91)])
        // Round-trip encode → decode is identity.
        let round = try dec.decode(Streams.self, from: JSONEncoder().encode(s2))
        XCTAssertEqual(round.ppgHr, s2.ppgHr)
    }
}
