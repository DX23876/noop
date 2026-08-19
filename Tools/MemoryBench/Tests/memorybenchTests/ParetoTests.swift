import XCTest

@testable import memorybench

/// The dominance rule, tested on hand-built rows.
///
/// It exists because a league table hid the decision: harrier scored best on retrieval while storing four times
/// the index, and printed as a ranking it simply "won". These assertions pin that a row only disappears from the
/// front when something genuinely beats it everywhere.
final class ParetoTests: XCTestCase {

    private func row(_ model: String,
                     ndcg: Double?,
                     indexKB: Int,
                     modelMB: Int? = 100,
                     embedSeconds: Double = 10,
                     dimensions: Int = 256,
                     matryoshka: Bool = true) -> ParetoRow {
        ParetoRow(model: model,
                  dimensions: dimensions,
                  matryoshka: matryoshka,
                  ndcg: ndcg,
                  indexBytes: indexKB * 1024,
                  modelFileBytes: modelMB.map { $0 * 1_048_576 },
                  embedMilliseconds: embedSeconds * 1000,
                  scoredQueries: 233)
    }

    func testAWorseRowOnEveryAxisIsDominated() {
        let rows = [row("good", ndcg: 0.8, indexKB: 100), row("bad", ndcg: 0.7, indexKB: 200)]
        XCTAssertEqual(paretoFront(rows), [0])
    }

    /// The case the section was built for: best quality at four times the index does not dominate, and is not
    /// dominated either. Both stay, and the choice is a trade.
    func testBetterQualityAtHigherCostDoesNotDominate() {
        let rows = [row("harrier-like", ndcg: 0.85, indexKB: 524),
                    row("gemma-like", ndcg: 0.755, indexKB: 131)]
        XCTAssertEqual(paretoFront(rows), [0, 1])
    }

    func testEqualQualityAtLowerCostDominates() {
        let rows = [row("expensive", ndcg: 0.80, indexKB: 400), row("cheap", ndcg: 0.80, indexKB: 100)]
        XCTAssertEqual(paretoFront(rows), [1])
    }

    /// Identical rows must not knock each other out — with `atLeastAsGood && strictlyBetter` neither is strictly
    /// better, so both stay. Getting this wrong would empty the front whenever a run was repeated.
    func testIdenticalRowsBothSurvive() {
        let rows = [row("a", ndcg: 0.8, indexKB: 100), row("b", ndcg: 0.8, indexKB: 100)]
        XCTAssertEqual(paretoFront(rows), [0, 1])
    }

    /// An unrecorded cost is unknown, not zero. Vector sets written before `modelFileBytes` existed have no
    /// size, and treating that as free would let them sweep the front by being unmeasurable.
    func testAMissingModelSizeCannotWinTheAxisItDoesNotHave() {
        let known = row("known-size", ndcg: 0.80, indexKB: 100, modelMB: 400)
        let unknown = row("unknown-size", ndcg: 0.80, indexKB: 100, modelMB: nil)
        // Neither dominates on model size, and they tie elsewhere, so both stay on the front.
        XCTAssertEqual(paretoFront([known, unknown]), [0, 1])
        // But an unknown size does not protect a row that is worse on an axis that IS measured.
        let worse = row("unknown-and-worse", ndcg: 0.70, indexKB: 200, modelMB: nil)
        XCTAssertEqual(paretoFront([known, worse]), [0])
    }

    /// A row with no quality number cannot be placed at all — a model that failed to load is not a cheap model.
    func testARowWithoutQualityIsNotOnTheFront() {
        let rows = [row("scored", ndcg: 0.5, indexKB: 500), row("failed", ndcg: nil, indexKB: 10)]
        XCTAssertEqual(paretoFront(rows), [0])
    }

    func testEmbedTimeIsADominanceAxisOfItsOwn() {
        let rows = [row("slow", ndcg: 0.8, indexKB: 100, embedSeconds: 45),
                    row("fast", ndcg: 0.8, indexKB: 100, embedSeconds: 25)]
        XCTAssertEqual(paretoFront(rows), [1])
    }
}
