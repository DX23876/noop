import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Adopted from ayiskakov/noop with the stager (`SleepStagerV3OracleTests`). Pins the Swift `SleepStagerTrained` to its Python reference (`Tools/SleepTrain/sleeptrain/features.py` and
/// `model.py`). `Tools/SleepTrain/make_oracle.py` runs the reference over SplitMix64 synthetic nights with the
/// committed model and writes `oracles/sleep_stager_v3.json`; this test rebuilds the same nights from the same
/// seeds and requires the port to agree: every sampled feature and both heads' posteriors within 1e-9
/// (relative), and the beat counts, the head chosen, every epoch label and the final segments exactly. The model was fitted on
/// features the reference computed, so a port that drifted from it would stage nights with a model trained on
/// different inputs, and nothing else would notice.
final class SleepStagerTrainedOracleTests: XCTestCase {

    private func loadOracle() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Oracles/sleep_stager_trained.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("committed oracle \(url.path) not found — this test must not pass by default")
            throw CocoaError(.fileNoSuchFile)
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        return root
    }

    /// SplitMix64, as `make_oracle.py` implements it.
    private struct SplitMix64 {
        var s: UInt64
        mutating func next() -> UInt64 {
            s = s &+ 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// `make_oracle.synth`, call for call: the order of every draw matters.
    private func synth(seed: Int, start: Int, epochs: Int, rr mode: String, hrGap: [Int]?)
        -> ([GravitySample], [HRSample], [RRInterval]) {
        var rng = SplitMix64(s: UInt64(seed))
        var stages: [Int] = []
        while stages.count < epochs {
            if stages.count < 20 { stages.append(0); continue }
            stages += [Int](repeating: 1, count: 10 + rng.below(20))
            stages += [Int](repeating: 2, count: 5 + rng.below(25))
            stages += [Int](repeating: 1, count: 5 + rng.below(15))
            stages += [Int](repeating: 3, count: 5 + rng.below(25))
            if rng.below(3) == 0 { stages += [Int](repeating: 0, count: 1 + rng.below(6)) }
        }
        stages = Array(stages.prefix(epochs))
        let baseHR = [72, 60, 54, 63], rsa = [30, 20, 35, 8]
        var posture = [700, 300, 600]
        var grav: [GravitySample] = [], hr: [HRSample] = []
        for s in 0..<(30 * epochs) {
            let st = stages[s / 30]
            if st == 0 && rng.below(40) == 0 {
                posture = [rng.below(2048) - 1024, rng.below(2048) - 1024, rng.below(2048) - 1024]
            }
            let amp = st == 0 && rng.below(4) == 0 ? 300 : (st == 3 ? 6 : 3)
            if rng.below(97) != 0 {
                let v = posture.map { Double($0 + rng.below(2 * amp + 1) - amp) / 1024.0 }
                grav.append(GravitySample(ts: start + s, x: v[0], y: v[1], z: v[2]))
            }
            let bpm = baseHR[st] + rng.below(7) - 3 + (s / 600) % 4
            let inGap = hrGap.map { $0[0] <= s && s < $0[1] } ?? false
            if !inGap && rng.below(53) != 0 { hr.append(HRSample(ts: start + s, bpm: bpm)) }
        }
        var rr: [RRInterval] = []
        if mode != "none" {
            var t = start * 1000 + 400
            let endMs = (start + 30 * epochs) * 1000
            while t < endMs {
                let s = t / 1000 - start
                let st = stages[min(s / 30, epochs - 1)]
                let tri = abs((t / 250) % 16 - 8)
                var v = 60000 / baseHR[st] + rsa[st] * tri / 8 - rsa[st] / 2 + rng.below(21) - 10
                if rng.below(211) == 0 { v *= 2 } else if rng.below(307) == 0 { v = 250 }
                t += v
                if mode == "sparse" && (s / 60) % 3 != 0 { continue }
                rr.append(RRInterval(ts: t / 1000, rrMs: v))
            }
        }
        return (grav, hr, rr)
    }

    private func close(_ a: Double, _ b: Double?, _ what: String) {
        guard let b = b else { XCTAssertTrue(a.isNaN, "\(what): expected missing, got \(a)"); return }
        XCTAssertFalse(a.isNaN, "\(what): expected \(b), got NaN")
        XCTAssertLessThanOrEqual(abs(a - b), 1e-9 * max(1, abs(b)), "\(what): \(a) vs \(b)")
    }

    func testPortMatchesTheReference() throws {
        let cases = try XCTUnwrap(try loadOracle()["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 4)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let start = try XCTUnwrap(c["start"] as? Int), epochs = try XCTUnwrap(c["epochs"] as? Int)
            let (synthGrav, hr, rr) = synth(seed: try XCTUnwrap(c["seed"] as? Int), start: start, epochs: epochs,
                                            rr: try XCTUnwrap(c["rr"] as? String), hrGap: c["hrGap"] as? [Int])
            // An HR-only night: the generator draws its gravity (so every later draw matches) and drops it.
            let grav = try XCTUnwrap(c["gravity"] as? Bool) ? synthGrav : []
            let samples = try XCTUnwrap(c["samples"] as? [String: Int])
            XCTAssertEqual([grav.count, hr.count, rr.count], [samples["grav"], samples["hr"], samples["rr"]],
                           "\(name): synthetic inputs differ from the generator's")
            let window = (c["window"] as? [Int]).map { (from: $0[0], to: $0[1]) }
            let end = start + 30 * epochs

            let spanStart = try XCTUnwrap(c["spanStart"] as? Int), n = try XCTUnwrap(c["n"] as? Int)
            let f = SleepStagerTrained.features(grav: grav, hr: hr, rr: rr, spanStart: spanStart, n: n)
            XCTAssertEqual(f.beats, try XCTUnwrap(c["beats"] as? [Int]), "\(name): beat counts")
            XCTAssertEqual(SleepStagerTrained.usesHRV(f) ? "hrv" : "base", c["head"] as? String, "\(name): head")
            let stride = try XCTUnwrap(c["stride"] as? Int)
            let picks = Array(Swift.stride(from: 0, to: n, by: stride))
            let expected = try XCTUnwrap(c["features"] as? [String: [Any]])
            for (feature, values) in expected {
                let col = try XCTUnwrap(f.columns[feature], "\(name): missing feature \(feature)")
                XCTAssertEqual(values.count, picks.count)
                for (k, i) in picks.enumerated() {
                    close(col[i], (values[k] as? NSNumber)?.doubleValue, "\(name) \(feature)[\(i)]")
                }
            }
            for (key, head) in [("hrvPosteriors", SleepStagerTrained.hrvHead), ("basePosteriors", SleepStagerTrained.baseHead)] {
                let post = head.posteriors(f)
                let expectedPost = try XCTUnwrap(c[key] as? [[Any]])
                for (k, i) in picks.enumerated() {
                    for s in 0..<4 {
                        close(post[i][s], (expectedPost[k][s] as? NSNumber)?.doubleValue, "\(name) \(key)[\(i)][\(s)]")
                    }
                }
            }

            let segments = SleepStagerTrained.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: [],
                                                      sleepWindow: window)
            let labels = SleepStagerTrained.epochStarts(start: start, end: end).map { e in
                segments.first { $0.start <= e && e < $0.end }?.stage ?? "?"
            }
            XCTAssertEqual(labels.map { String($0.prefix(1)) }.joined(), c["labels"] as? String, "\(name): labels")
            let expectedSegments = try XCTUnwrap(c["segments"] as? [[Any]])
            XCTAssertEqual(segments.count, expectedSegments.count, "\(name): segment count")
            for (seg, e) in zip(segments, expectedSegments) {
                XCTAssertEqual(seg, StageSegment(start: e[0] as! Int, end: e[1] as! Int, stage: e[2] as! String))
            }
        }
    }

    /// A column missing for the whole night takes the head's training mean, so it standardises to 0 and moves
    /// no logit; a partly missing column takes the night's median. A whole-night gap used to take 0, which for
    /// a percentile rank reads as the night's extreme: no heart rate at all read as the lowest, flattest heart
    /// rate of the night.
    func testAColumnMissingAllNightMovesNoLogit() {
        XCTAssertEqual(SleepStagerTrained.imputed([.nan, .nan], absent: 0.5), [0.5, 0.5])
        XCTAssertEqual(SleepStagerTrained.imputed([.nan, 1, 3, 2], absent: 0.5), [2, 1, 3, 2])
        let head = SleepStagerTrained.baseHead, n = 3
        var columns: [String: [Double]] = [:]
        for (j, name) in head.features.enumerated() { columns[name] = [Double](repeating: head.mean[j], count: n) }
        let atMean = head.posteriors(SleepStagerTrained.Features(n: n, columns: columns, beats: [0, 0, 0]))
        for name in ["hr_pct", "hrsd5_pct", "hr_over_low"] { columns[name] = [.nan, .nan, .nan] }
        XCTAssertEqual(head.posteriors(SleepStagerTrained.Features(n: n, columns: columns, beats: [0, 0, 0])), atMean)
    }

    /// The Welch band powers equal a direct evaluation of the density on a signal with known content: a pure
    /// 0.25 Hz tone puts the HF peak on that bin, and its LF power is negligible next to HF.
    func testSpectralPeakTracksAToneAndMovesWithIt() {
        for (hz, bin) in [(0.25, 16), (0.203125, 13), (0.34375, 22)] {
            var t: [Double] = [], v: [Double] = []
            var time = 0.0
            while time < 290 {
                let rr = 1000 + 40 * sin(2 * Double.pi * hz * time)
                t.append(time); v.append(rr)
                time += rr / 1000
            }
            let (lf, hf, peak, peaked) = SleepStagerTrained.spectral(t, v)
            XCTAssertEqual(peak, Double(bin) / 64, accuracy: 1e-12, "tone \(hz) Hz")
            XCTAssertLessThan(lf, hf / 50)
            XCTAssertGreaterThan(peaked, 0.3)
        }
    }

    /// Outside the band window every epoch is wake, and a window that holds no epoch leaves the night awake
    /// instead of staging it anyway.
    func testEpochsOutsideTheWindowAreWake() {
        let start = 1_700_000_010, end = start + 3 * 3600
        let grav = (0..<(end - start)).map { GravitySample(ts: start + $0, x: 0.7, y: 0.3, z: 0.6) }
        let hr = (0..<(end - start)).map { HRSample(ts: start + $0, bpm: 58 + $0 % 5) }
        let w = (from: start + 3600, to: start + 7200)
        let epochs = SleepStagerTrained.epochStarts(start: start, end: end)
        let labels = SleepStagerTrained.stageEpochs(epochs: epochs, grav: grav, hr: hr, rr: [], sleepWindow: w, end: end)
        for (e, l) in zip(epochs, labels) where !SleepStagerTrained.epochInSleepWindow(e, w, end: end) {
            XCTAssertEqual(l, "wake")
        }
        XCTAssertTrue(labels.contains { $0 != "wake" })
        let empty = SleepStagerTrained.stageEpochs(epochs: epochs, grav: grav, hr: hr, rr: [],
                                              sleepWindow: (from: end + 60, to: end + 600), end: end)
        XCTAssertEqual(Set(empty), ["wake"])
    }
}
