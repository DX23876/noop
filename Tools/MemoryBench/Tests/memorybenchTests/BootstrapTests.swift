import XCTest

@testable import memorybench

/// The paired bootstrap, pinned on hand-built per-query scores. Pure arithmetic, no corpus and no model.
///
/// This exists because several conclusions in this tool's history were rankings built on differences the
/// corpus could not resolve — one model read 0.850, then 0.806, then 0.677 as the measurement got more
/// honest, and a 0.004 gap was once reported as an ordering. An interval is the cheapest thing that stops it.
final class BootstrapTests: XCTestCase {

    private func scores(_ values: [Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: values.enumerated().map { ("q\($0.offset)", $0.element) })
    }

    /// A difference present in every single query, with no variance, must come back conclusive — and the
    /// interval must be tight rather than merely non-zero.
    func testAConsistentImprovementIsResolved() throws {
        let baseline = scores(Array(repeating: 0.5, count: 40))
        let candidate = scores(Array(repeating: 0.6, count: 40))
        let interval = try XCTUnwrap(pairedBootstrap(baseline: baseline, candidate: candidate))
        XCTAssertEqual(interval.delta, 0.1, accuracy: 1e-9)
        XCTAssertFalse(interval.isInconclusive)
        XCTAssertEqual(interval.low, 0.1, accuracy: 1e-9)
        XCTAssertEqual(interval.high, 0.1, accuracy: 1e-9)
    }

    /// Pure noise around zero must NOT be resolved, however many queries there are. This is the case that used
    /// to be reported as a ranking.
    func testNoiseAroundZeroIsReportedAsIndistinguishable() throws {
        var rng = SplitMix64(seed: 99)
        let baseline = scores((0..<60).map { _ in Double(rng.next() % 1000) / 1000 })
        var candidate: [String: Double] = [:]
        for (key, value) in baseline {
            // ±0.1 jitter with no systematic direction.
            candidate[key] = value + (Double(rng.next() % 200) - 100) / 1000
        }
        let interval = try XCTUnwrap(pairedBootstrap(baseline: baseline, candidate: candidate))
        XCTAssertTrue(interval.isInconclusive, "a directionless difference must not be called a win")
    }

    /// What actually makes a difference unresolvable is variance in the DIFFERENCES, not in the scores.
    ///
    /// Worth pinning because the distinction is easy to get backwards — this test was first written with
    /// wildly varying scores but a constant +0.02 gap, and the bootstrap resolved it, correctly. Pairing
    /// removes score variance entirely; only a difference that changes sign from query to query is beyond the
    /// corpus's reach. That is also why an interval estimated from score variance is far too pessimistic.
    func testAnInconsistentEffectIsNotResolvedEvenWithAPositiveMean() throws {
        var rng = SplitMix64(seed: 7)
        var baseline: [String: Double] = [:]
        var candidate: [String: Double] = [:]
        for index in 0..<35 {
            let base = Double(rng.next() % 1000) / 1000
            baseline["q\(index)"] = base
            // A small positive mean, but the sign flips per query — helps some questions, hurts others.
            let swing = rng.next() % 2 == 0 ? 0.30 : -0.26
            candidate["q\(index)"] = max(0, min(1, base + swing))
        }
        let interval = try XCTUnwrap(pairedBootstrap(baseline: baseline, candidate: candidate))
        XCTAssertTrue(interval.isInconclusive,
                      "a difference that changes sign per query must not be claimed as a win")
    }

    /// The flip side, and the reason the paired form is worth the trouble: a SMALL but consistent difference is
    /// resolvable even when the underlying scores swing across the whole range.
    func testASmallButConsistentEffectIsResolvedDespiteWildScoreVariance() throws {
        var rng = SplitMix64(seed: 11)
        var baseline: [String: Double] = [:]
        var candidate: [String: Double] = [:]
        for index in 0..<35 {
            let base = Double(rng.next() % 900) / 1000        // 0.0 ... 0.9, wide spread
            baseline["q\(index)"] = base
            candidate["q\(index)"] = base + 0.02             // the same tiny gain every time
        }
        let interval = try XCTUnwrap(pairedBootstrap(baseline: baseline, candidate: candidate))
        XCTAssertFalse(interval.isInconclusive)
        XCTAssertEqual(interval.delta, 0.02, accuracy: 1e-9)
    }

    /// Deterministic for a seed, or a reported interval could not be reproduced and would shift on every run.
    func testTheIntervalIsReproducible() throws {
        var rng = SplitMix64(seed: 3)
        let baseline = scores((0..<30).map { _ in Double(rng.next() % 1000) / 1000 })
        let candidate = scores((0..<30).map { _ in Double(rng.next() % 1000) / 1000 })
        let a = try XCTUnwrap(pairedBootstrap(baseline: baseline, candidate: candidate, seed: 4242))
        let b = try XCTUnwrap(pairedBootstrap(baseline: baseline, candidate: candidate, seed: 4242))
        XCTAssertEqual(a.low, b.low)
        XCTAssertEqual(a.high, b.high)
    }

    /// Only queries BOTH variants scored may be compared. A variant that stays silent on a question has no
    /// score there, and quietly comparing it against the baseline's score would credit or blame it for a
    /// question it never answered.
    func testOnlySharedQueriesAreCompared() throws {
        let baseline = scores([0.5, 0.5, 0.5, 0.5])
        var candidate = scores([0.9, 0.9, 0.9, 0.9])
        candidate.removeValue(forKey: "q3")
        let interval = try XCTUnwrap(pairedBootstrap(baseline: baseline, candidate: candidate))
        XCTAssertEqual(interval.n, 3)
        XCTAssertEqual(interval.delta, 0.4, accuracy: 1e-9)
    }

    /// Nothing to compare must be nil rather than a fabricated zero-width interval around zero.
    func testTooFewSharedQueriesYieldsNoInterval() {
        XCTAssertNil(pairedBootstrap(baseline: scores([0.5]), candidate: scores([0.9])))
        XCTAssertNil(pairedBootstrap(baseline: [:], candidate: [:]))
    }

    /// A regression has to be detectable as such, not merely as "not an improvement".
    func testAConsistentRegressionIsResolvedAsWorse() throws {
        let baseline = scores(Array(repeating: 0.8, count: 40))
        let candidate = scores(Array(repeating: 0.6, count: 40))
        let interval = try XCTUnwrap(pairedBootstrap(baseline: baseline, candidate: candidate))
        XCTAssertLessThan(interval.delta, 0)
        XCTAssertFalse(interval.isInconclusive)
        XCTAssertLessThan(interval.high, 0)
    }
}
