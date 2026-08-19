import XCTest

@testable import memorybench

/// The pure half of the trivial-pair check: `evaluate` scoring hand-built vectors, with no model, no network
/// and no live embedder — the same split as everywhere else pure scoring logic in this tool is pinned.
/// `runSanityCheck` (the impure half that actually calls a model) is exercised only by a real `embed` run.
final class SanityCheckTests: XCTestCase {

    // MARK: - The data itself

    /// Guards against an editing slip more than a design flaw: a pair whose "wrong" document accidentally
    /// duplicates the correct one, or a blank field, would make the check trivially pass or crash rather than
    /// test anything.
    func testEveryPairIsWellFormed() {
        for pair in SanityPair.all {
            XCTAssertFalse(pair.query.isEmpty, "\(pair.id) has no query")
            XCTAssertFalse(pair.correct.isEmpty, "\(pair.id) has no correct document")
            XCTAssertFalse(pair.wrong.isEmpty, "\(pair.id) has no wrong document")
            XCTAssertNotEqual(pair.correct, pair.wrong, "\(pair.id): correct and wrong must differ")
        }
        XCTAssertEqual(Set(SanityPair.all.map(\.id)).count, SanityPair.all.count, "duplicate pair id")
    }

    /// At least one pair has to be in a non-English shipped locale, or the check would never have caught a
    /// model that only degenerates outside English — which is the more likely failure mode for a multilingual
    /// claim than uniform breakage.
    func testAtLeastOnePairIsNotEnglish() {
        XCTAssertTrue(SanityPair.all.contains { $0.query.contains("ß") || $0.query.contains("ä")
            || $0.query.contains("ü") || $0.correct.contains("ä") })
    }

    // MARK: - evaluate, on synthetic vectors

    /// Orthonormal-ish hand-built vectors: `basis` points straight at one axis, close-to-basis is a small
    /// perturbation toward another, so cosine similarity is easy to reason about by hand.
    private func basis(_ dimension: Int, width: Int = 4) -> [Float] {
        var v = [Float](repeating: 0, count: width)
        v[dimension] = 1
        return v
    }

    private func nudge(_ vector: [Float], toward other: Int, amount: Float) -> [Float] {
        var v = vector
        v[other] += amount
        let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        return v.map { $0 / norm }
    }

    func testEvaluatePassesWhenTheCorrectDocumentScoresHigher() throws {
        let pair = SanityPair.all[0]
        let query = basis(0)
        let vectors = [
            pair.keys.query: query,
            pair.keys.correct: nudge(basis(0), toward: 1, amount: 0.05),   // close to the query
            pair.keys.wrong: basis(2),                                    // orthogonal to the query
        ]
        let result = try XCTUnwrap(SanityCheck.evaluate([pair], vectors: vectors).first)
        XCTAssertTrue(result.passed)
        XCTAssertGreaterThan(result.correctScore, result.wrongScore)
    }

    /// The case this check exists for: a degenerate model that scores the wrong document higher, the way the
    /// broken multilingual-e5-small quant did (0.9367 for an off-topic passage against 0.9303 for the right
    /// one — both plausible-looking numbers, and only their ORDER was wrong).
    func testEvaluateFailsWhenTheWrongDocumentScoresHigher() throws {
        let pair = SanityPair.all[0]
        let query = basis(0)
        let vectors = [
            pair.keys.query: query,
            pair.keys.correct: basis(2),
            pair.keys.wrong: nudge(basis(0), toward: 1, amount: 0.05),
        ]
        let result = try XCTUnwrap(SanityCheck.evaluate([pair], vectors: vectors).first)
        XCTAssertFalse(result.passed)
    }

    func testEvaluateCoversEveryPairInOrder() throws {
        let vectors = Dictionary(uniqueKeysWithValues: SanityPair.all.flatMap { pair -> [(String, [Float])] in
            let keys = pair.keys
            return [(keys.query, basis(0)), (keys.correct, basis(0)), (keys.wrong, basis(1))]
        })
        let results = try SanityCheck.evaluate(SanityPair.all, vectors: vectors)
        XCTAssertEqual(results.map(\.pair.id), SanityPair.all.map(\.id))
        XCTAssertTrue(results.allSatisfy(\.passed))
    }

    func testEvaluateThrowsRatherThanSilentlySkippingAMissingVector() {
        let pair = SanityPair.all[0]
        let incomplete = [pair.keys.query: basis(0), pair.keys.correct: basis(0)]   // "wrong" missing
        XCTAssertThrowsError(try SanityCheck.evaluate([pair], vectors: incomplete))
    }
}
