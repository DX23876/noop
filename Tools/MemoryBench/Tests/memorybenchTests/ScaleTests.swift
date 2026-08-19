import XCTest

@testable import memorybench

/// The filler generator, tested on its own. Everything here is pure: no store, no corpus, no vectors file.
///
/// It needs testing precisely because it is the part that could quietly decide the answer. Filler calibrated too
/// tightly makes every distractor a near-duplicate and K=32 look hopeless; calibrated too loosely it sits
/// orthogonal to everything and makes the scan look free. So the calibration is asserted rather than trusted.
final class ScaleTests: XCTestCase {

    private func unitVector(_ dimensions: Int, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        let raw = (0..<dimensions).map { _ in Float(Int(rng.next() % 2_000) - 1_000) / 1_000 }
        let norm = sqrt(raw.reduce(0.0) { $0 + Double($1 * $1) })
        return raw.map { Float(Double($0) / norm) }
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Double {
        zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    }

    /// The property the whole tier rests on: asking for a cosine gets that cosine. The tolerance is loose
    /// because the construction is stochastic — the expectation is exact, a single draw is not.
    func testFillerHitsItsTargetCosine() {
        let parent = unitVector(256, seed: 1)
        for target in [0.2, 0.4, 0.6, 0.8] {
            var rng = SplitMix64(seed: 99)
            let achieved = (0..<40).map { _ -> Double in
                dot(parent, fillerVector(from: parent, targetCosine: target, rng: &rng))
            }
            let mean = achieved.reduce(0, +) / Double(achieved.count)
            XCTAssertEqual(mean, target, accuracy: 0.06, "asked for \(target), got \(mean)")
        }
    }

    func testFillerIsAUnitVector() {
        let parent = unitVector(256, seed: 2)
        var rng = SplitMix64(seed: 7)
        for target in [0.0, 0.3, 0.9] {
            let filler = fillerVector(from: parent, targetCosine: target, rng: &rng)
            XCTAssertEqual(sqrt(dot(filler, filler)), 1, accuracy: 1e-4,
                           "a non-unit filler would distort every cosine in the tier")
        }
    }

    /// The tail of a real cosine distribution includes zero and below, and the σ formula diverges there. The
    /// fallback has to be a genuinely random direction, which in 256 dimensions means near-orthogonal.
    func testANonPositiveTargetFallsBackToARandomDirection() {
        let parent = unitVector(256, seed: 3)
        var rng = SplitMix64(seed: 11)
        let achieved = (0..<40).map { _ -> Double in
            abs(dot(parent, fillerVector(from: parent, targetCosine: 0, rng: &rng)))
        }
        XCTAssertLessThan(achieved.reduce(0, +) / Double(achieved.count), 0.12)
    }

    func testSamplingThePairwiseSpreadIsDeterministicAndSorted() {
        let vectors = (0..<50).map { unitVector(64, seed: UInt64($0) + 100) }
        let a = sampledPairwiseCosines(vectors, samples: 500, seed: 4242)
        let b = sampledPairwiseCosines(vectors, samples: 500, seed: 4242)
        XCTAssertEqual(a, b, "a tier must be reproducible from its seed")
        XCTAssertEqual(a, a.sorted())
        XCTAssertEqual(sampledPairwiseCosines([], samples: 10, seed: 1), [])
        XCTAssertEqual(sampledPairwiseCosines([unitVector(8, seed: 1)], samples: 10, seed: 1), [])
    }

    /// A self-pair would report cosine 1 and pull the calibration towards near-duplicates.
    func testSamplingNeverComparesAVectorWithItself() {
        let vectors = (0..<4).map { unitVector(32, seed: UInt64($0) + 200) }
        let sampled = sampledPairwiseCosines(vectors, samples: 400, seed: 5)
        XCTAssertLessThan(sampled.last!, 0.999, "a self-pair leaked into the spread")
    }
}
