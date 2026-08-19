import XCTest

@testable import memorybench

/// The metrics are pure functions over ranked id lists and judgment tables, so they are pinned here on
/// hand-built inputs — no vectors file, no model, no corpus, no `--vectors` argument.
final class MetricsTests: XCTestCase {

    // MARK: - nDCG

    func testPerfectRankingScoresOne() {
        let judgments = ["a": 2, "b": 1, "c": 0]
        XCTAssertEqual(normalizedDCG(ranked: ["a", "b", "c"], judgments: judgments)!, 1, accuracy: 1e-9)
    }

    func testGradeTwoOutranksThreeGradeOnes() {
        // The reason the gain is exponential rather than linear: the one document the question is actually
        // about must be worth more than a handful of loosely-related lines, or a selection that fills the
        // context with near-misses scores better than one that answers.
        let judgments = ["target": 2, "near1": 1, "near2": 1, "near3": 1]
        let answered = normalizedDCG(ranked: ["target"], judgments: judgments)!
        let padded = normalizedDCG(ranked: ["near1", "near2", "near3"], judgments: judgments)!
        XCTAssertGreaterThan(answered, padded)
    }

    /// The load-bearing `nil`. An `irrelevant` query has no ideal ranking, so nDCG is undefined — and
    /// returning 0 instead would average in a penalty for the behaviour the corpus is asking for, rewarding
    /// a system that pads every turn with eight lines.
    func testQueryWithNothingRelevantHasNoNDCG() {
        XCTAssertNil(normalizedDCG(ranked: ["a", "b"], judgments: ["a": 0, "b": 0]))
        XCTAssertNil(normalizedDCG(ranked: [], judgments: [:]))
    }

    func testIdealIsTruncatedAtKSoADeepCorpusCannotMakeAPerfectRunLookBad() {
        // Nine relevant documents, eight slots: retrieving the best eight is a perfect run at k = 8.
        var judgments: [String: Int] = [:]
        for index in 0..<9 { judgments["d\(index)"] = 2 }
        let ranked = (0..<8).map { "d\($0)" }
        XCTAssertEqual(normalizedDCG(ranked: ranked, judgments: judgments, k: 8)!, 1, accuracy: 1e-9)
    }

    func testRankOrderMatters() {
        let judgments = ["a": 2, "b": 1]
        let good = normalizedDCG(ranked: ["a", "b"], judgments: judgments)!
        let bad = normalizedDCG(ranked: ["b", "a"], judgments: judgments)!
        XCTAssertGreaterThan(good, bad)
    }

    // MARK: - Precision

    /// Precision divides by what was EMITTED, not by k. A selection that returns two lines, both correct,
    /// is perfectly precise; marking it down to 0.25 for declining to invent six more would penalise exactly
    /// the restraint the floor is meant to introduce.
    func testPrecisionDividesByEmittedNotByK() {
        let judgments = ["a": 2, "b": 2]
        XCTAssertEqual(precision(ranked: ["a", "b"], judgments: judgments)!, 1, accuracy: 1e-9)
        XCTAssertEqual(precision(ranked: ["a", "b", "x", "y"], judgments: judgments)!, 0.5, accuracy: 1e-9)
    }

    func testPrecisionOfAnEmptyResultIsUndefinedRatherThanZero() {
        XCTAssertNil(precision(ranked: [], judgments: ["a": 2]))
    }

    // MARK: - Recall and MRR

    func testRecallCountsDistinctRelevantSourcesFound() {
        let judgments = ["a": 2, "b": 1, "c": 1]
        XCTAssertEqual(recall(ranked: ["a"], judgments: judgments, k: 1)!, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(recall(ranked: ["a", "x", "b"], judgments: judgments, k: 3)!, 2.0 / 3, accuracy: 1e-9)
    }

    func testReciprocalRankFindsTheFirstRelevantPosition() {
        let judgments = ["a": 2]
        XCTAssertEqual(reciprocalRank(ranked: ["a"], judgments: judgments)!, 1, accuracy: 1e-9)
        XCTAssertEqual(reciprocalRank(ranked: ["x", "a"], judgments: judgments)!, 0.5, accuracy: 1e-9)
    }

    func testReciprocalRankIsZeroWhenNothingRelevantIsRetrieved() {
        XCTAssertEqual(reciprocalRank(ranked: ["x", "y"], judgments: ["a": 2])!, 0, accuracy: 1e-9)
    }

    func testEmittedLineCountIsCappedAtK() {
        XCTAssertEqual(emittedLineCount(ranked: Array(repeating: "a", count: 20)), 8)
        XCTAssertEqual(emittedLineCount(ranked: []), 0)
    }

    // MARK: - Selection shape

    /// Eight relevant lines from one conversation can score perfectly on every retrieval metric above while
    /// being exactly the failure the diversity cap exists for. This is the metric that notices.
    func testDominanceSpotsOneThreadTakingEveryLine() {
        XCTAssertEqual(dominance(Array(repeating: "thread-1", count: 8)), 1, accuracy: 1e-9)
        XCTAssertEqual(dominance(["a", "a", "b", "c"]), 0.5, accuracy: 1e-9)
        XCTAssertEqual(dominance([]), 0, accuracy: 1e-9)
    }

    func testUnderrunOnlyFiresWhenThereWasMaterialForMoreLines() {
        XCTAssertTrue(slotUnderrun(emitted: 4, availableRelevant: 6))
        XCTAssertFalse(slotUnderrun(emitted: 4, availableRelevant: 4))
        // Nine relevant documents but only eight slots: filling all eight is not an underrun.
        XCTAssertFalse(slotUnderrun(emitted: 8, availableRelevant: 9))
    }

    // MARK: - Aggregation

    func testMeanReportsHowManyQueriesItCovered() {
        let result = mean([1.0, nil, 0.0])!
        XCTAssertEqual(result.value, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.count, 2, "a variant that improves the mean by scoring fewer queries has not improved anything")
    }

    func testMeanOfNothingDefinedIsNil() {
        XCTAssertNil(mean([nil, nil]))
    }

    // MARK: - Abstention and coverage

    /// The floor's largest measured effect is invisible in nDCG, because nDCG is `nil` for an unanswerable
    /// query by construction. These are the columns that make it visible.
    func testAbstentionRateCountsQueriesAnsweredWithNothing() {
        XCTAssertEqual(abstentionRate(emittedCounts: [0, 0, 8, 8])!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(abstentionRate(emittedCounts: [0, 0, 0])!, 1, accuracy: 1e-9)
        XCTAssertEqual(abstentionRate(emittedCounts: [8, 8])!, 0, accuracy: 1e-9)
    }

    /// The cost side of every threshold, and the number that had no metric at all before. A floor tuned to
    /// silence noise will eventually silence answers, and without this column a tighter floor looks free.
    func testFalseAbstentionCountsAnswerableQueriesLeftUnanswered() {
        XCTAssertEqual(falseAbstentionRate(emittedCounts: [0, 3, 3, 3])!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(falseAbstentionRate(emittedCounts: [5, 5])!, 0, accuracy: 1e-9)
    }

    func testAbstentionMetricsAreNilRatherThanZeroWithNothingToScore() {
        XCTAssertNil(abstentionRate(emittedCounts: []))
        XCTAssertNil(falseAbstentionRate(emittedCounts: []))
        XCTAssertNil(meanEmittedLines([]))
    }

    /// Precision alone rewards silence: one correct line out of one emitted is P@8 = 1.0. This is the column
    /// that exposes it, which is why the two are always printed together.
    func testMeanEmittedLinesExposesPrecisionBoughtBySilence() throws {
        let conservative = [1, 1, 1, 1]
        let generous = [8, 8, 8, 8]
        XCTAssertEqual(meanEmittedLines(conservative)!, 1, accuracy: 1e-9)
        XCTAssertEqual(meanEmittedLines(generous)!, 8, accuracy: 1e-9)
        // Same perfect precision, wildly different coverage — indistinguishable without this metric.
        let judgments = ["a": 2, "b": 2, "c": 2]
        XCTAssertEqual(precision(ranked: ["a"], judgments: judgments)!, 1, accuracy: 1e-9)
        XCTAssertEqual(precision(ranked: ["a", "b", "c"], judgments: judgments)!, 1, accuracy: 1e-9)
        XCTAssertLessThan(recall(ranked: ["a"], judgments: judgments, k: 8)!,
                          recall(ranked: ["a", "b", "c"], judgments: judgments, k: 8)!)
    }
}

/// Why the report prints `hit@1` and not `R@1`.
///
/// `recall(k: 1)` divides by how many relevant documents a query has, so one slot cannot hold three answers and
/// the metric is capped at 1/|relevant| however perfect the ranking is. Read as a hit rate — which is how almost
/// everyone reads "R@1" — it understates the ranking badly. These tests pin both the trap and the replacement.
final class HitRateTests: XCTestCase {

    func testRecallAtOneIsCappedByHowManyAnswersAQueryHas() {
        let three = ["a": 3, "b": 2, "c": 1]
        // A perfect ranking, and recall@1 still reads 0.333 — the other two answers cannot fit in one slot.
        XCTAssertEqual(recall(ranked: ["a", "b", "c"], judgments: three, k: 1)!, 1.0 / 3, accuracy: 1e-9)
        // The same perfect ranking on a single-answer query reads 1.0. The two numbers are not comparable, which
        // is exactly why a mean over mixed queries partly measures judgment density instead of retrieval.
        XCTAssertEqual(recall(ranked: ["a"], judgments: ["a": 3], k: 1)!, 1, accuracy: 1e-9)
    }

    func testHitRateAsksTheQuestionPeopleThinkRecallAtOneAsks() {
        let three = ["a": 3, "b": 2, "c": 1]
        XCTAssertEqual(hitRate(ranked: ["a", "b", "c"], judgments: three)!, 1, accuracy: 1e-9)
        XCTAssertEqual(hitRate(ranked: ["x", "a"], judgments: three)!, 0, accuracy: 1e-9)
    }

    /// Undefined rather than 0 for a query with nothing to find, like every other metric here: an `unanswerable`
    /// query has no top line to get right, and averaging in a zero would punish correct silence.
    func testHitRateIsUndefinedWhenNothingIsRelevant() {
        XCTAssertNil(hitRate(ranked: ["a"], judgments: ["a": 0]))
        XCTAssertNil(hitRate(ranked: [], judgments: [:]))
    }

    /// An empty result is a miss, not undefined — the query HAD an answer and no line was emitted.
    func testEmittingNothingOnAnAnswerableQueryIsAMiss() {
        XCTAssertEqual(hitRate(ranked: [], judgments: ["a": 3])!, 0, accuracy: 1e-9)
    }
}
